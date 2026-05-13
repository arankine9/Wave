#if canImport(AVFoundation) && canImport(Foundation)
@preconcurrency import AVFoundation
import Foundation
import FluidAudio

/// Local STT backed by FluidAudio's Parakeet TDT v2 (English-only, highest
/// recall). Captures mic audio via AVAudioEngine with Apple's system voice
/// processing enabled so background voices and noise are suppressed *before*
/// audio reaches Parakeet. Buffers 16 kHz mono Float samples; transcribes
/// the full buffer on `finalize()`. Models are downloaded lazily on the
/// first `startSession()` call.
public final class ParakeetBackend: STTBackend, @unchecked Sendable {
    public struct Config: Sendable {
        public var modelVersion: AsrModelVersion
        public var enableVoiceProcessing: Bool
        public var verboseLog: Bool

        public init(
            modelVersion: AsrModelVersion = .v2,
            // Apple's VPIO on macOS AVAudioEngine reports a 9-channel input
            // format on the M3 Pro built-in mic and then refuses engine.start
            // with -10875 (format not supported) when the input is routed to
            // any standard output node. Disabled by default until we find the
            // right macOS wiring — see Sources/BeckCore/STT/ParakeetBackend.swift
            // for the broken VPIO graph code, kept around for future debugging.
            enableVoiceProcessing: Bool = false,
            verboseLog: Bool = false
        ) {
            self.modelVersion = modelVersion
            self.enableVoiceProcessing = enableVoiceProcessing
            self.verboseLog = verboseLog
        }
    }

    private let config: Config
    private let asrManager: AsrManager
    private let state = LoadState()
    public let log: ParakeetLog
    /// Fires from the audio render thread with mic RMS each tap (~85 ms at
    /// 48 kHz / 4096 frames). Set once at startup; captured into each new
    /// session created by `startSession()`.
    public var levelObserver: (@Sendable (Float) -> Void)?

    public init(config: Config = Config()) {
        self.config = config
        self.asrManager = AsrManager(config: .default)
        self.log = ParakeetLog(enabled: config.verboseLog)
    }

    public func startSession() async throws -> STTSession {
        log.log("startSession: awaiting model load")
        try await ensureModelsLoaded()
        log.log("startSession: models loaded, opening AVAudioEngine session")
        let session = try ParakeetSession(
            asrManager: asrManager,
            config: config,
            log: log,
            levelObserver: levelObserver
        )
        log.log("startSession: session active (voiceProcessing=\(config.enableVoiceProcessing))")
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
    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter
    private let buffer = SampleBuffer()
    private let log: ParakeetLog

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

        let input = engine.inputNode

        // Apple system voice processing: AEC + noise/voice suppression. Must
        // be enabled before the engine starts. Pipeline order:
        // mic → Apple voice processing → Parakeet.
        if config.enableVoiceProcessing {
            do {
                try input.setVoiceProcessingEnabled(true)
                log.log("session: voice processing enabled")

                // Voice Processing IO on macOS needs a complete graph (input
                // routed to an output) for the unit to actually emit audio.
                // Without it, inputNode delivers noise-floor silence on every
                // channel. Use mainMixerNode (which auto-attaches to the
                // output node) with nil format so AVAudioEngine picks a
                // compatible pair, then mute mainMixer so the user doesn't
                // hear themselves through the speakers.
                let mixer = engine.mainMixerNode
                engine.connect(input, to: mixer, format: nil)
                mixer.outputVolume = 0
                log.log("session: VPIO graph wired (input → mainMixer @ vol 0)")
            } catch {
                log.log("session: setVoiceProcessingEnabled failed (\(error.localizedDescription)); proceeding without it")
            }
        }

        let inFormat = input.outputFormat(forBus: 0)
        log.log("session: input format sampleRate=\(inFormat.sampleRate) channels=\(inFormat.channelCount)")
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw STTError.engineError("could not create 16 kHz mono Float target format")
        }
        self.targetFormat = target
        guard let conv = AVAudioConverter(from: inFormat, to: target) else {
            throw STTError.engineError("could not create audio converter")
        }
        self.converter = conv

        let sink = buffer
        let format = targetFormat
        let converterRef = converter
        let logRef = log
        let counter = TapCounter()
        // Tap the input in its native format (after voice processing applies).
        // We resample to 16 kHz mono Float inside the tap via AVAudioConverter.
        // Tapping with a different `format:` lets AVAudioEngine attempt the
        // conversion itself, but with post-voice-processing multi-channel
        // input that path silently delivers silence — keep manual control.
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { audioBuffer, _ in
            let frames = audioBuffer.frameLength
            let n = counter.bump()
            if n <= 3 || n % 25 == 0 {
                logRef.log("tap #\(n): \(frames) frames in")
            }
            if let observer = levelObserver {
                observer(Self.rms(buffer: audioBuffer))
            }
            Self.tap(
                audioBuffer: audioBuffer,
                inFormat: inFormat,
                targetFormat: format,
                converter: converterRef,
                sink: sink,
                log: logRef,
                callIndex: n
            )
        }

        engine.prepare()
        do {
            try engine.start()
            log.log("session: engine started (mic indicator should be live)")
        } catch {
            log.log("session: engine.start() FAILED — \(error.localizedDescription)")
            throw STTError.engineError("audio engine start: \(error.localizedDescription)")
        }
    }

    func finalize() async throws -> String {
        guard buffer.claimFinalize() else { throw STTError.sessionNotActive }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)

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
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        _ = buffer.drain()
        continuation.finish()
    }

    /// RMS of the first channel, Float32-only. Returns 0 if the buffer is
    /// in a non-float format. Fast: single channel, no allocation.
    static func rms(buffer: AVAudioPCMBuffer) -> Float {
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

    private static func tap(
        audioBuffer: AVAudioPCMBuffer,
        inFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        converter: AVAudioConverter,
        sink: SampleBuffer,
        log: ParakeetLog,
        callIndex: Int
    ) {
        let ratio = 16000.0 / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(audioBuffer.frameLength) * ratio + 8)
        guard outCapacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
        else {
            if callIndex <= 3 { log.log("tap #\(callIndex): outCapacity=\(outCapacity) — skip") }
            return
        }

        var error: NSError?
        let supplied = ConverterSuppliedFlag()
        // CRITICAL: signal .noDataNow (not .endOfStream) after supplying this
        // tap's buffer. .endOfStream tells the converter the entire stream is
        // over and it refuses all subsequent input — which would freeze the
        // recording after the very first tap callback.
        let status = converter.convert(to: outBuffer, error: &error) { _, statusOut in
            if supplied.value { statusOut.pointee = .noDataNow; return nil }
            supplied.value = true; statusOut.pointee = .haveData
            return audioBuffer
        }
        // Probe every input channel — voice-processed input sometimes places
        // the processed signal in a non-zero channel.
        var inMax: Float = 0
        var perChannelMax: [Float] = []
        if let channelData = audioBuffer.floatChannelData {
            let n = Int(audioBuffer.frameLength)
            let chCount = Int(audioBuffer.format.channelCount)
            for ch in 0..<chCount {
                var m: Float = 0
                let buf = channelData[ch]
                for i in 0..<n { let v = abs(buf[i]); if v > m { m = v } }
                perChannelMax.append(m)
                if m > inMax { inMax = m }
            }
        }

        if callIndex <= 3 {
            let perCh = perChannelMax.enumerated().map { "ch\($0)=\(String(format: "%.3f", $1))" }.joined(separator: " ")
            log.log("tap #\(callIndex): convert status=\(status.rawValue) error=\(error?.localizedDescription ?? "nil") outFrames=\(outBuffer.frameLength) inMax=\(String(format: "%.3f", inMax)) [\(perCh)]")
        }
        guard error == nil,
              outBuffer.frameLength > 0,
              let channel = outBuffer.floatChannelData?[0]
        else { return }

        let count = Int(outBuffer.frameLength)
        var outMax: Float = 0
        for i in 0..<count { let v = abs(channel[i]); if v > outMax { outMax = v } }
        if callIndex <= 3 || (callIndex % 25 == 0) {
            log.log("tap #\(callIndex): outMax=\(String(format: "%.3f", outMax))")
        }
        let chunk = Array(UnsafeBufferPointer(start: channel, count: count))
        sink.append(chunk)
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
