#if canImport(AVFoundation) && canImport(Foundation)
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import FluidAudio

/// Local STT backed by FluidAudio's Parakeet TDT v2 (English-only, highest
/// recall). Captures mic audio via AVCaptureSession (not AVAudioEngine) so
/// the input keeps flowing when the user's default audio *output* is a
/// Bluetooth A2DP speaker or AirPlay receiver — see `ParakeetSession.init`
/// for the long story. Buffers 16 kHz mono Float samples; transcribes the
/// full buffer on `finalize()`. Models are downloaded lazily on the first
/// `startSession()` call.
public final class ParakeetBackend: STTBackend, @unchecked Sendable {
    public struct Config: Sendable {
        public var modelVersion: AsrModelVersion
        public var verboseLog: Bool
        /// Queried at the start of every session so changes in user settings
        /// take effect on the next dictation without re-creating the backend.
        public var microphoneChoiceProvider: @Sendable () -> MicrophoneChoice

        public init(
            modelVersion: AsrModelVersion = .v2,
            verboseLog: Bool = false,
            microphoneChoiceProvider: @escaping @Sendable () -> MicrophoneChoice = { .builtIn }
        ) {
            self.modelVersion = modelVersion
            self.verboseLog = verboseLog
            self.microphoneChoiceProvider = microphoneChoiceProvider
        }
    }

    private let config: Config
    private let asrManager: AsrManager
    private let state = LoadState()
    public let log: ParakeetLog
    /// Fires from the audio capture queue with mic RMS for each delivered
    /// sample buffer. Set once at startup; captured into each new session
    /// created by `startSession()`.
    public var levelObserver: (@Sendable (Float) -> Void)?

    public init(config: Config = Config()) {
        self.config = config
        self.asrManager = AsrManager(config: .default)
        self.log = ParakeetLog(enabled: config.verboseLog)
    }

    public func startSession() async throws -> STTSession {
        log.log("startSession: awaiting model load")
        try await ensureModelsLoaded()
        log.log("startSession: models loaded, opening capture session")
        let session = try ParakeetSession(
            asrManager: asrManager,
            config: config,
            log: log,
            levelObserver: levelObserver
        )
        log.log("startSession: session active")
        return session
    }

    /// Pre-warm the model: forces the lazy download/load step before the user
    /// triggers their first dictation. Safe to call from app startup.
    public func prewarm() async throws {
        log.log("prewarm: begin")
        try await ensureModelsLoaded()
        log.log("prewarm: complete")
    }

    private func ensureModelsLoaded() async throws {
        if state.isLoaded() {
            log.log("ensureModelsLoaded: already loaded")
            return
        }
        log.log("ensureModelsLoaded: loading (downloadAndLoad version=\(config.modelVersion))")
        let task = state.beginOrJoinLoad {
            let version = self.config.modelVersion
            let manager = self.asrManager
            return Task<Void, Error> {
                let models = try await AsrModels.downloadAndLoad(version: version)
                try await manager.loadModels(models)
            }
        }
        do {
            try await task.value
            state.markLoaded()
            log.log("ensureModelsLoaded: success")
        } catch {
            state.clearLoad()
            log.log("ensureModelsLoaded: FAILED — \(error.localizedDescription)")
            throw STTError.backendUnavailable("Parakeet model load failed: \(error.localizedDescription)")
        }
    }
}

/// Owns the load-once latch and the in-flight load task. All state mutation
/// happens in synchronous methods so the lock is never held across `await`.
private final class LoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var task: Task<Void, Error>?

    func isLoaded() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded
    }

    func beginOrJoinLoad(_ make: () -> Task<Void, Error>) -> Task<Void, Error> {
        lock.lock(); defer { lock.unlock() }
        if let existing = task { return existing }
        let new = make()
        task = new
        return new
    }

    func markLoaded() {
        lock.lock(); defer { lock.unlock() }
        loaded = true
        task = nil
    }

    func clearLoad() {
        lock.lock(); defer { lock.unlock() }
        task = nil
    }
}

final class ParakeetSession: STTSession, @unchecked Sendable {
    let partials: AsyncStream<STTPartial>
    private let continuation: AsyncStream<STTPartial>.Continuation
    private let asrManager: AsrManager
    private let captureSession = AVCaptureSession()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "com.wave.audio.capture")
    private let buffer = SampleBuffer()
    private let log: ParakeetLog
    private let delegate: AudioCaptureDelegate

    init(
        asrManager: AsrManager,
        config: ParakeetBackend.Config,
        log: ParakeetLog,
        levelObserver: (@Sendable (Float) -> Void)? = nil
    ) throws {
        self.asrManager = asrManager
        self.log = log

        var c: AsyncStream<STTPartial>.Continuation!
        self.partials = AsyncStream { c = $0 }
        self.continuation = c

        // Why AVCaptureSession instead of AVAudioEngine:
        // AVAudioEngine on macOS is a full-duplex graph. Even with no
        // output connections, it implicitly references its outputNode
        // during prepare()/start() and the engine's clock domain follows
        // the system default output device. When that device is a
        // Bluetooth A2DP speaker or an AirPlay receiver, the wireless
        // clock can't be reconciled with the built-in mic's clock — the
        // engine silently delivers zero buffers, the macOS mic indicator
        // never lights, and dictation captures nothing. Filed as Apple
        // Feedback FB8996889, unfixed for years. AVCaptureSession opens
        // an input-only IOProc on the device we hand it and ignores the
        // system default output entirely, so the route doesn't matter.
        guard let device = Self.resolveCaptureDevice(
            choice: config.microphoneChoiceProvider(),
            log: log
        ) else {
            throw STTError.engineError("no microphone device available")
        }
        log.log("session: capturing from \"\(device.localizedName)\" (uniqueID=\(device.uniqueID))")

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw STTError.engineError("could not create 16 kHz mono Float target format")
        }

        let delegate = AudioCaptureDelegate(
            targetFormat: target,
            sink: buffer,
            log: log,
            levelObserver: levelObserver
        )
        self.delegate = delegate

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw STTError.engineError("AVCaptureDeviceInput: \(error.localizedDescription)")
        }

        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw STTError.engineError("AVCaptureSession refused mic input")
        }
        captureSession.addInput(input)

        guard captureSession.canAddOutput(audioOutput) else {
            captureSession.commitConfiguration()
            throw STTError.engineError("AVCaptureSession refused audio output")
        }
        captureSession.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(delegate, queue: captureQueue)
        captureSession.commitConfiguration()

        captureSession.startRunning()
        log.log("session: AVCaptureSession started (mic indicator should be live)")
    }

    func finalize() async throws -> String {
        guard buffer.claimFinalize() else { throw STTError.sessionNotActive }

        if captureSession.isRunning { captureSession.stopRunning() }

        let captured = buffer.drain()
        let seconds = Double(captured.count) / 16000.0
        log.log("finalize: captured \(captured.count) samples (\(String(format: "%.2f", seconds))s)")
        defer { continuation.finish() }

        // Skip transcription for very short captures (<0.2s) — Parakeet would
        // still run and may hallucinate. 16 kHz * 0.2s = 3200 samples.
        guard captured.count >= 3200 else {
            log.log("finalize: clip too short, skipping transcribe")
            return ""
        }

        let result: ASRResult
        do {
            let layers = await asrManager.decoderLayerCount
            var state = try TdtDecoderState(decoderLayers: layers)
            let t0 = Date()
            result = try await asrManager.transcribe(captured, decoderState: &state)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            log.log("finalize: transcribe \(ms)ms → \"\(result.text)\"")
        } catch {
            log.log("finalize: transcribe FAILED — \(error.localizedDescription)")
            throw STTError.engineError("parakeet transcribe: \(error.localizedDescription)")
        }
        let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            continuation.yield(STTPartial(text: trimmed, isFinal: true))
        }
        return trimmed
    }

    func cancel() {
        if captureSession.isRunning { captureSession.stopRunning() }
        _ = buffer.drain()
        continuation.finish()
    }

    /// Maps `MicrophoneChoice` onto an `AVCaptureDevice`. CoreAudio device
    /// UIDs and `AVCaptureDevice.uniqueID` match on macOS for audio devices,
    /// so the UID a user pinned via Settings (which came from
    /// `AudioInputDevices.available()`) is the same string we look up here.
    /// `.specific` falls back to built-in if the device isn't connected;
    /// `.builtIn` falls back to system default if no built-in mic exists.
    static func resolveCaptureDevice(choice: MicrophoneChoice, log: ParakeetLog) -> AVCaptureDevice? {
        switch choice {
        case .systemDefault:
            log.log("session: mic choice = systemDefault")
            return AVCaptureDevice.default(for: .audio)
        case .builtIn:
            log.log("session: mic choice = builtIn")
            if let dev = builtInCaptureDevice() { return dev }
            log.log("session: built-in mic not found — falling back to system default")
            return AVCaptureDevice.default(for: .audio)
        case .specific(let uid):
            if let dev = audioDiscoverySession.devices.first(where: { $0.uniqueID == uid }) {
                log.log("session: mic choice = specific(uid=\(uid))")
                return dev
            }
            log.log("session: mic choice = specific(uid=\(uid)) not connected — falling back to built-in")
            if let dev = builtInCaptureDevice() { return dev }
            return AVCaptureDevice.default(for: .audio)
        }
    }

    private static func builtInCaptureDevice() -> AVCaptureDevice? {
        if let dev = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified) {
            return dev
        }
        // Fallback: cross-reference CoreAudio's transport-type-based built-in
        // detection. Some Macs report `.microphone` via the discovery API but
        // `AVCaptureDevice.default(.microphone, ...)` returns nil; matching
        // by UID from the HAL still works.
        if let coreaudioBuiltIn = AudioInputDevices.builtIn() {
            return audioDiscoverySession.devices.first(where: { $0.uniqueID == coreaudioBuiltIn.uid })
        }
        return nil
    }

    private static let audioDiscoverySession = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone],
        mediaType: .audio,
        position: .unspecified
    )
}

/// AVCaptureAudioDataOutput delivers `CMSampleBuffer`s on the capture queue.
/// Each callback: copy PCM data into an `AVAudioPCMBuffer` in the device's
/// native format, then resample to 16 kHz mono Float via `AVAudioConverter`
/// and append to the session's shared sample sink. The converter is created
/// lazily on the first buffer (input format isn't known until then) and
/// recreated if the format ever changes mid-session.
fileprivate final class AudioCaptureDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private let sink: SampleBuffer
    private let log: ParakeetLog
    private let levelObserver: (@Sendable (Float) -> Void)?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let counter = TapCounter()

    init(
        targetFormat: AVAudioFormat,
        sink: SampleBuffer,
        log: ParakeetLog,
        levelObserver: (@Sendable (Float) -> Void)?
    ) {
        self.targetFormat = targetFormat
        self.sink = sink
        self.log = log
        self.levelObserver = levelObserver
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let n = counter.bump()
        guard let pcmBuffer = Self.pcmBuffer(from: sampleBuffer) else {
            if n <= 3 { log.log("sample #\(n): could not extract PCM buffer") }
            return
        }
        if n <= 3 || n % 25 == 0 {
            log.log("sample #\(n): \(pcmBuffer.frameLength) frames in (rate=\(pcmBuffer.format.sampleRate) ch=\(pcmBuffer.format.channelCount))")
        }

        if let observer = levelObserver {
            observer(Self.rms(buffer: pcmBuffer))
        }

        if converter == nil || converterInputFormat?.isEqual(pcmBuffer.format) == false {
            converterInputFormat = pcmBuffer.format
            converter = AVAudioConverter(from: pcmBuffer.format, to: targetFormat)
            if converter == nil {
                log.log("sample #\(n): AVAudioConverter creation FAILED for input \(pcmBuffer.format)")
                return
            }
            log.log("sample #\(n): converter ready for input \(pcmBuffer.format)")
        }
        guard let conv = converter else { return }

        let ratio = targetFormat.sampleRate / pcmBuffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(pcmBuffer.frameLength) * ratio + 8)
        guard outCapacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
        else {
            if n <= 3 { log.log("sample #\(n): outCapacity=\(outCapacity) — skip") }
            return
        }

        var error: NSError?
        let supplied = ConverterSuppliedFlag()
        // .noDataNow (not .endOfStream) after supplying this buffer —
        // .endOfStream would close the converter to all subsequent input.
        let status = conv.convert(to: outBuffer, error: &error) { _, statusOut in
            if supplied.value { statusOut.pointee = .noDataNow; return nil }
            supplied.value = true; statusOut.pointee = .haveData
            return pcmBuffer
        }
        guard error == nil,
              outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData?[0]
        else {
            if n <= 3 {
                log.log("sample #\(n): convert status=\(status.rawValue) error=\(error?.localizedDescription ?? "nil") outFrames=\(outBuffer.frameLength)")
            }
            return
        }

        let count = Int(outBuffer.frameLength)
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        sink.append(chunk)
    }

    /// Copies the CMSampleBuffer's PCM payload into a freshly allocated
    /// AVAudioPCMBuffer in the same format. The audio data is copied (not
    /// referenced) so the CMSampleBuffer can be released immediately after
    /// this returns.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let numFrames = Int32(CMSampleBufferGetNumSamples(sampleBuffer))
        guard numFrames > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numFrames))
        else { return nil }
        pcmBuffer.frameLength = AVAudioFrameCount(numFrames)

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: numFrames,
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return nil }
        return pcmBuffer
    }

    /// RMS of the first channel, Float32-only. Returns 0 if the buffer is
    /// in a non-float format. Fast: single channel, no allocation.
    private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        let ch = channelData[0]
        var sumSq: Float = 0
        for i in 0..<n {
            let s = ch[i]
            sumSq += s * s
        }
        return (sumSq / Float(n)).squareRoot()
    }
}

private final class TapCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int = 0
    func bump() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

private final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var finalized = false

    func append(_ chunk: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard !finalized else { return }
        samples.append(contentsOf: chunk)
    }

    func drain() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let out = samples
        samples.removeAll(keepingCapacity: false)
        return out
    }

    func claimFinalize() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finalized { return false }
        finalized = true
        return true
    }
}

private final class ConverterSuppliedFlag: @unchecked Sendable {
    var value: Bool = false
}

/// Lightweight logger toggled per backend instance. Writes to stderr when
/// enabled so the CLI harness can capture it without interfering with the
/// stdout-printed transcript.
public final class ParakeetLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled: Bool

    public init(enabled: Bool) {
        self._enabled = enabled
    }

    public var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    public func log(_ message: @autoclosure () -> String) {
        let on: Bool = { lock.lock(); defer { lock.unlock() }; return _enabled }()
        guard on else { return }
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[parakeet \(ts)] \(message())\n".utf8))
    }
}
#endif
