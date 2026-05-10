#if canImport(Speech) && canImport(AVFoundation)
import AVFoundation
import Foundation
import Speech

public final class AppleSpeechBackend: STTBackend {
    private let locale: Locale

    public init(locale: Locale = Locale(identifier: "en-US")) throws {
        guard SFSpeechRecognizer(locale: locale) != nil else {
            throw STTError.backendUnavailable("SFSpeechRecognizer unavailable for \(locale.identifier)")
        }
        self.locale = locale
    }

    public func startSession() async throws -> STTSession {
        try await Self.ensureAuthorized()
        return try AppleSpeechSession(locale: locale)
    }

    private static func ensureAuthorized() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        let granted: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status)
            }
        }
        guard granted == .authorized else {
            throw STTError.notAuthorized
        }
    }
}

final class AppleSpeechSession: STTSession {
    private let recognizer: SFSpeechRecognizer
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let engine: AVAudioEngine
    private var task: SFSpeechRecognitionTask?
    private var continuation: AsyncStream<STTPartial>.Continuation?
    private var finalContinuation: CheckedContinuation<String, Error>?
    private var lastTranscript: String = ""
    private let lock = NSLock()

    let partials: AsyncStream<STTPartial>

    init(locale: Locale) throws {
        guard let r = SFSpeechRecognizer(locale: locale) else {
            throw STTError.backendUnavailable("SFSpeechRecognizer init failed")
        }
        self.recognizer = r
        self.request = SFSpeechAudioBufferRecognitionRequest()
        self.engine = AVAudioEngine()

        var cont: AsyncStream<STTPartial>.Continuation!
        self.partials = AsyncStream { c in cont = c }
        self.continuation = cont

        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        try installTapAndStart()
    }

    private func installTapAndStart() throws {
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw STTError.engineError(error.localizedDescription)
        }
        self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                self.lock.lock(); self.lastTranscript = text; self.lock.unlock()
                self.continuation?.yield(STTPartial(text: text, isFinal: result.isFinal))
                if result.isFinal {
                    self.continuation?.finish()
                    self.completeFinal(.success(text))
                }
            }
            if let error {
                self.continuation?.finish()
                self.completeFinal(.failure(STTError.engineError(error.localizedDescription)))
            }
        }
    }

    func finalize() async throws -> String {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()

        return try await withCheckedThrowingContinuation { c in
            lock.lock()
            if finalContinuation != nil {
                lock.unlock()
                c.resume(throwing: STTError.sessionAlreadyActive)
                return
            }
            finalContinuation = c
            lock.unlock()
        }
    }

    func cancel() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request.endAudio()
        task?.cancel()
        continuation?.finish()
        completeFinal(.failure(STTError.sessionNotActive))
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
