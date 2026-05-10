#if canImport(AVFoundation) && canImport(Foundation)
import AVFoundation
import Foundation

/// Spawns the Python sidecar (`Sources/python/voxtral_sidecar.py`) and bridges
/// audio from AVAudioEngine into it via the JSONL protocol. If the sidecar
/// isn't installed or fails to load the model, `startSession` throws and the
/// `STTBackendFactory` callers can fall back to Apple Speech.
public final class VoxtralBackend: STTBackend, @unchecked Sendable {
    public struct Config: Sendable {
        public var pythonPath: String
        public var sidecarScriptPath: String
        public var startupTimeoutSeconds: TimeInterval

        public init(
            pythonPath: String? = nil,
            sidecarScriptPath: String? = nil,
            startupTimeoutSeconds: TimeInterval = 60
        ) {
            self.pythonPath = pythonPath
                ?? ProcessInfo.processInfo.environment["VOXFLOW_VOXTRAL_PYTHON"]
                ?? "/usr/bin/env"
            self.sidecarScriptPath = sidecarScriptPath
                ?? Self.defaultSidecarPath()
            self.startupTimeoutSeconds = startupTimeoutSeconds
        }

        static func defaultSidecarPath() -> String {
            // When the .app bundle ships the sidecar it lives next to the
            // executable; in development we point at the source tree.
            let bundleSidecar = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/voxtral_sidecar.py")
                .path
            if FileManager.default.fileExists(atPath: bundleSidecar) {
                return bundleSidecar
            }
            return "Sources/python/voxtral_sidecar.py"
        }
    }

    private let config: Config
    private var sidecar: SidecarProcess?

    public init(config: Config = Config()) {
        self.config = config
    }

    public func startSession() async throws -> STTSession {
        let process = try await ensureSidecar()
        return try VoxtralSession(process: process)
    }

    private func ensureSidecar() async throws -> SidecarProcess {
        if let sidecar, sidecar.isAlive { return sidecar }
        let process = try SidecarProcess(config: config)
        try await process.waitForReady(timeout: config.startupTimeoutSeconds)
        sidecar = process
        return process
    }

    public func shutdown() {
        sidecar?.shutdown()
        sidecar = nil
    }
}

/// One Process running the Python sidecar. Long-lived across dictations.
final class SidecarProcess: @unchecked Sendable {
    private let process: Process
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    private var readBuffer = Data()
    private let lock = NSLock()
    private var subscribers: [(SidecarEvent) -> Void] = []
    private var isReady = false

    init(config: VoxtralBackend.Config) throws {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()

        if config.pythonPath.hasSuffix("/env") {
            process.executableURL = URL(fileURLWithPath: config.pythonPath)
            process.arguments = ["python3", config.sidecarScriptPath]
        } else {
            process.executableURL = URL(fileURLWithPath: config.pythonPath)
            process.arguments = [config.sidecarScriptPath]
        }
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        self.process = process
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.handleStdout(data)
        }

        do {
            try process.run()
        } catch {
            throw STTError.engineError("voxtral sidecar spawn: \(error.localizedDescription)")
        }
    }

    var isAlive: Bool { process.isRunning }

    func waitForReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if lock.withLock({ isReady }) { return }
            if !process.isRunning {
                throw STTError.engineError("voxtral sidecar exited during startup")
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw STTError.engineError("voxtral sidecar did not become ready within \(Int(timeout))s")
    }

    func subscribe(_ handler: @escaping (SidecarEvent) -> Void) {
        lock.lock(); subscribers.append(handler); lock.unlock()
    }

    func unsubscribeAll() {
        lock.lock(); subscribers.removeAll(); lock.unlock()
    }

    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        var line = data
        line.append(0x0A)
        stdinPipe.fileHandleForWriting.write(line)
    }

    func shutdown() {
        send(["action": "shutdown"])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [process] in
            if process.isRunning { process.terminate() }
        }
    }

    private func handleStdout(_ data: Data) {
        lock.lock()
        readBuffer.append(data)
        var lines: [Data] = []
        while let nl = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.subdata(in: 0..<nl)
            readBuffer.removeSubrange(0...nl)
            if !line.isEmpty { lines.append(line) }
        }
        let snapshot = subscribers
        lock.unlock()

        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            guard let kind = obj["event"] as? String else { continue }
            let event: SidecarEvent
            switch kind {
            case "ready":
                lock.lock(); isReady = true; lock.unlock()
                event = .ready
            case "partial":
                event = .partial(obj["text"] as? String ?? "")
            case "final":
                event = .final(obj["text"] as? String ?? "")
            case "error":
                event = .error(obj["message"] as? String ?? "unknown")
            default:
                continue
            }
            for sub in snapshot { sub(event) }
        }
    }
}

final class SuppliedFlag: @unchecked Sendable {
    var value: Bool = false
}

enum SidecarEvent: Sendable {
    case ready
    case partial(String)
    case final(String)
    case error(String)
}

final class VoxtralSession: STTSession, @unchecked Sendable {
    let partials: AsyncStream<STTPartial>
    private let continuation: AsyncStream<STTPartial>.Continuation
    private let process: SidecarProcess
    private let engine = AVAudioEngine()
    private var finalContinuation: CheckedContinuation<String, Error>?
    private let lock = NSLock()

    init(process: SidecarProcess) throws {
        self.process = process
        var c: AsyncStream<STTPartial>.Continuation!
        self.partials = AsyncStream { c = $0 }
        self.continuation = c

        process.subscribe { [weak self] event in
            self?.handle(event)
        }
        process.send(["action": "start", "sample_rate": 16000])

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        )!
        let converter = AVAudioConverter(from: format, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, let converter else { return }
            let outFrameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * 16000.0 / format.sampleRate
            )
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat, frameCapacity: outFrameCount
            ) else { return }
            var error: NSError?
            let supplied = SuppliedFlag()
            converter.convert(to: outBuffer, error: &error) { _, statusOut in
                if supplied.value { statusOut.pointee = .endOfStream; return nil }
                supplied.value = true; statusOut.pointee = .haveData
                return buffer
            }
            if error == nil, let int16Data = outBuffer.int16ChannelData {
                let count = Int(outBuffer.frameLength) * MemoryLayout<Int16>.size
                let data = Data(bytes: int16Data[0], count: count)
                self.process.send([
                    "action": "audio",
                    "data": data.base64EncodedString(),
                    "sample_rate": 16000,
                ])
            }
        }
        engine.prepare()
        try engine.start()
    }

    func finalize() async throws -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        process.send(["action": "finalize"])
        return try await withCheckedThrowingContinuation { c in
            lock.lock(); finalContinuation = c; lock.unlock()
        }
    }

    func cancel() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        process.unsubscribeAll()
        completeFinal(.failure(STTError.sessionNotActive))
    }

    private func handle(_ event: SidecarEvent) {
        switch event {
        case .ready: break
        case .partial(let text):
            continuation.yield(STTPartial(text: text, isFinal: false))
        case .final(let text):
            continuation.yield(STTPartial(text: text, isFinal: true))
            continuation.finish()
            completeFinal(.success(text))
        case .error(let message):
            continuation.finish()
            completeFinal(.failure(STTError.engineError(message)))
        }
    }

    private func completeFinal(_ result: Result<String, Error>) {
        lock.lock()
        let c = finalContinuation
        finalContinuation = nil
        lock.unlock()
        c?.resume(with: result)
    }
}
#endif
