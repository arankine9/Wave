#if canImport(AVFoundation)
import AVFoundation
import Foundation

public enum AudioRecorderError: Error {
    case engineError(String)
    case alreadyRunning
}

/// Captures raw microphone audio via AVAudioEngine. The recorder owns the
/// engine and exposes a callback per buffer so consumers (STT backends, the
/// status pill waveform, the debug ring buffer) can subscribe.
public final class AudioRecorder {
    public typealias BufferHandler = @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "com.wave.audio")
    private var handlers: [UUID: BufferHandler] = [:]
    private var isRunning = false

    public init() {}

    public func subscribe(_ handler: @escaping BufferHandler) -> UUID {
        let id = UUID()
        queue.sync { handlers[id] = handler }
        return id
    }

    public func unsubscribe(_ id: UUID) {
        queue.sync { _ = handlers.removeValue(forKey: id) }
    }

    public func start() throws {
        guard !isRunning else { throw AudioRecorderError.alreadyRunning }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, time in
            self?.dispatch(buffer: buffer, time: time)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioRecorderError.engineError(error.localizedDescription)
        }
        isRunning = true
    }

    public func stop() {
        guard isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        isRunning = false
    }

    public var inputFormat: AVAudioFormat {
        engine.inputNode.outputFormat(forBus: 0)
    }

    private func dispatch(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let snapshot = queue.sync { handlers }
        for handler in snapshot.values {
            handler(buffer, time)
        }
    }
}
#endif
