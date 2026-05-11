#if canImport(AVFoundation) && canImport(Foundation)
import AVFoundation
import Foundation

/// Local STT backed by `whisper-cli` (the `whisper.cpp` Homebrew binary).
/// Records mic audio into a temp WAV via AVAudioEngine, then on `finalize()`
/// invokes whisper-cli to transcribe the file. Metal-accelerated on Apple
/// Silicon. No Apple Speech Recognition entitlement is required.
public final class WhisperCppBackend: STTBackend, @unchecked Sendable {
    public struct Config: Sendable {
        public var binaryPath: String
        public var modelPath: String
        public var language: String
        public var threads: Int

        public init(
            binaryPath: String? = nil,
            modelPath: String? = nil,
            language: String = "en",
            threads: Int = 4
        ) {
            self.binaryPath = binaryPath ?? Self.defaultBinaryPath()
            self.modelPath = modelPath ?? Self.defaultModelPath()
            self.language = language
            self.threads = threads
        }

        static func defaultBinaryPath() -> String {
            if let env = ProcessInfo.processInfo.environment["VOXFLOW_WHISPER_BIN"],
               !env.isEmpty { return env }
            for candidate in ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"] {
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
            return "/opt/homebrew/bin/whisper-cli"
        }

        static func defaultModelPath() -> String {
            if let env = ProcessInfo.processInfo.environment["VOXFLOW_WHISPER_MODEL"],
               !env.isEmpty { return env }
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(".voxflow/models/ggml-base.en.bin").path
        }
    }

    private let config: Config

    public init(config: Config = Config()) throws {
        guard FileManager.default.isExecutableFile(atPath: config.binaryPath) else {
            throw STTError.backendUnavailable(
                "whisper-cli not found at \(config.binaryPath). Install with: brew install whisper-cpp"
            )
        }
        guard FileManager.default.fileExists(atPath: config.modelPath) else {
            throw STTError.backendUnavailable(
                "whisper model not found at \(config.modelPath). Download with: " +
                "mkdir -p ~/.voxflow/models && curl -L -o ~/.voxflow/models/ggml-base.en.bin " +
                "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
            )
        }
        self.config = config
    }

    public func startSession() async throws -> STTSession {
        return try WhisperCppSession(config: config)
    }

    /// Static probe used by the factory so we can fall back gracefully without
    /// constructing an instance. Mirrors `init`'s checks.
    public static func isAvailable(config: Config = Config()) -> Bool {
        return FileManager.default.isExecutableFile(atPath: config.binaryPath)
            && FileManager.default.fileExists(atPath: config.modelPath)
    }

    /// One-shot file transcription. Exposed so tests can drive whisper.cpp
    /// without spinning up AVAudioEngine. Returns the trimmed transcript.
    public static func transcribe(
        wavPath: String,
        config: Config = Config()
    ) async throws -> String {
        let raw = try await runWhisperCli(
            binaryPath: config.binaryPath,
            modelPath: config.modelPath,
            wavPath: wavPath,
            language: config.language,
            threads: config.threads
        )
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Spawn whisper-cli on the given WAV file and return raw stdout.
/// Top-level so both the static helper and the session use one code path.
@Sendable func runWhisperCli(
    binaryPath: String,
    modelPath: String,
    wavPath: String,
    language: String,
    threads: Int
) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binaryPath)
    process.arguments = [
        "-m", modelPath,
        "-f", wavPath,
        "-l", language,
        "-t", String(threads),
        "-nt",   // no timestamps
        "-np",   // no extra prints
    ]
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        throw STTError.engineError("whisper-cli spawn: \(error.localizedDescription)")
    }

    return try await withCheckedThrowingContinuation { c in
        process.terminationHandler = { proc in
            let outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            let errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let outText = String(data: outData, encoding: .utf8) ?? ""
            if proc.terminationStatus == 0 {
                c.resume(returning: outText)
            } else {
                let errText = String(data: errData, encoding: .utf8) ?? ""
                let detail = errText.isEmpty ? outText : errText
                c.resume(throwing: STTError.engineError(
                    "whisper-cli exit=\(proc.terminationStatus): \(detail.prefix(400))"
                ))
            }
        }
    }
}

final class WhisperCppSession: STTSession, @unchecked Sendable {
    private let config: WhisperCppBackend.Config
    private let engine = AVAudioEngine()
    private let wavURL: URL
    private var audioFile: AVAudioFile?
    private let lock = NSLock()
    private var didFinalize = false

    let partials: AsyncStream<STTPartial>
    private let continuation: AsyncStream<STTPartial>.Continuation

    init(config: WhisperCppBackend.Config) throws {
        self.config = config

        var c: AsyncStream<STTPartial>.Continuation!
        self.partials = AsyncStream { c = $0 }
        self.continuation = c

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxflow-\(UUID().uuidString).wav")
        self.wavURL = tmp

        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
        let writeSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        do {
            self.audioFile = try AVAudioFile(forWriting: wavURL, settings: writeSettings)
        } catch {
            throw STTError.engineError("create wav: \(error.localizedDescription)")
        }

        let converter = AVAudioConverter(from: inFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            guard let self, let converter else { return }
            let outFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / inFormat.sampleRate
            )
            guard outFrameCount > 0,
                  let outBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat, frameCapacity: outFrameCount
                  )
            else { return }
            var error: NSError?
            let supplied = SuppliedFlag()
            converter.convert(to: outBuffer, error: &error) { _, statusOut in
                if supplied.value { statusOut.pointee = .endOfStream; return nil }
                supplied.value = true; statusOut.pointee = .haveData
                return buffer
            }
            if error == nil, outBuffer.frameLength > 0 {
                self.appendBuffer(outBuffer)
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw STTError.engineError("audio engine start: \(error.localizedDescription)")
        }
    }

    func finalize() async throws -> String {
        guard claimFinalize() else { throw STTError.sessionNotActive }

        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        // Close the wav file by dropping the reference; AVAudioFile flushes on dealloc.
        closeAudioFile()

        defer {
            try? FileManager.default.removeItem(at: wavURL)
            continuation.finish()
        }

        // If the user spoke nothing the file is tiny; whisper would still run
        // and likely hallucinate. Skip when under ~0.2s of audio (6.4 KB).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: wavURL.path),
           let size = attrs[.size] as? NSNumber, size.intValue < 6400 {
            return ""
        }

        let text = try await runWhisper()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            continuation.yield(STTPartial(text: trimmed, isFinal: true))
        }
        return trimmed
    }

    func cancel() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        closeAudioFile()
        try? FileManager.default.removeItem(at: wavURL)
        continuation.finish()
    }

    private func claimFinalize() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if didFinalize { return false }
        didFinalize = true
        return true
    }

    private func closeAudioFile() {
        lock.lock(); audioFile = nil; lock.unlock()
    }

    private func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let file = audioFile
        lock.unlock()
        try? file?.write(from: buffer)
    }

    private func runWhisper() async throws -> String {
        return try await runWhisperCli(
            binaryPath: config.binaryPath,
            modelPath: config.modelPath,
            wavPath: wavURL.path,
            language: config.language,
            threads: config.threads
        )
    }
}
#endif
