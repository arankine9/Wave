import Foundation

public struct DictationTrace: Sendable, Equatable {
    public var sttMs: Int = 0
    public var cleanupMs: Int = 0
    public var pasteMs: Int = 0
    public var path: CleanupResult.Path = .skipped
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var rawTranscript: String = ""
    public var finalText: String = ""

    public init() {}
}

public protocol DictationLogger: AnyObject, Sendable {
    func record(_ trace: DictationTrace)
}

/// State machine for one dictation cycle. The hotkey controller's events are
/// the only inputs from outside; the orchestrator owns the STT session and
/// drives audio -> transcript -> cleanup -> paste sequentially. State updates
/// are pushed onto the supplied AppState so the menu bar reflects progress.
public actor DictationOrchestrator {
    private let backend: STTBackend
    private let cleanup: CleanupPipeline
    private let paster: Paster
    private let appState: AppState
    private let clock: BeckClock
    private let logger: DictationLogger?

    private var activeSession: STTSession?
    private var activeStartedAt: TimeInterval = 0

    public init(
        backend: STTBackend,
        cleanup: CleanupPipeline,
        paster: Paster,
        appState: AppState,
        clock: BeckClock = RealClock(),
        logger: DictationLogger? = nil
    ) {
        self.backend = backend
        self.cleanup = cleanup
        self.paster = paster
        self.appState = appState
        self.clock = clock
        self.logger = logger
    }

    public func handle(_ event: HotkeyEvent) async {
        switch event {
        case .startRecording(let reason):
            await startSession(reason: reason)
        case .stopRecording:
            await finishSession()
        }
    }

    public func cancel() async {
        activeSession?.cancel()
        activeSession = nil
        appState.setStatus(.idle)
    }

    private func startSession(reason: HotkeyEvent.Reason) async {
        guard activeSession == nil else { return }
        appState.setStatus(.recording)
        appState.setPartial("")
        activeStartedAt = clock.now()
        do {
            let session = try await backend.startSession()
            activeSession = session
            // Pump partials into AppState so the status pill can render them
            // live. Detached so we don't block startSession's caller.
            let stream = session.partials
            let state = appState
            Task.detached {
                for await partial in stream {
                    state.setPartial(partial.text)
                }
            }
        } catch {
            appState.setStatus(.error("STT start: \(error)"))
            activeSession = nil
        }
        _ = reason
    }

    private func finishSession() async {
        guard let session = activeSession else {
            appState.setStatus(.idle)
            return
        }
        activeSession = nil

        var trace = DictationTrace()

        appState.setStatus(.transcribing)
        let sttStart = clock.now()
        let raw: String
        do {
            raw = try await session.finalize()
        } catch {
            appState.setStatus(.error("STT finalize: \(error)"))
            return
        }
        trace.sttMs = Int((clock.now() - sttStart) * 1000)
        trace.rawTranscript = raw

        appState.setStatus(.cleaning)
        let cleanupStart = clock.now()
        let result: CleanupResult
        do {
            result = try await cleanup.run(rawTranscript: raw)
        } catch {
            appState.setStatus(.error("Cleanup: \(error)"))
            return
        }
        trace.cleanupMs = Int((clock.now() - cleanupStart) * 1000)
        trace.path = result.path
        trace.inputTokens = result.inputTokens
        trace.outputTokens = result.outputTokens
        trace.finalText = result.text

        if !result.text.isEmpty {
            appState.setStatus(.pasting)
            let pasteStart = clock.now()
            do {
                try paster.paste(result.text)
            } catch {
                appState.setStatus(.error("Paste: \(error)"))
                return
            }
            trace.pasteMs = Int((clock.now() - pasteStart) * 1000)
        }

        appState.setStatus(.idle)
        logger?.record(trace)
    }
}
