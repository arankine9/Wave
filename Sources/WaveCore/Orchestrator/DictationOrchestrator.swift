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
    private let clock: WaveClock
    private let logger: DictationLogger?

    private var activeSession: STTSession?
    private var activeStartedAt: TimeInterval = 0
    /// Set true once `.startRecording` is received. Distinguishes pre-roll
    /// (armed but not yet committed) from a real recording that should
    /// finalize on stop. A `.stopRecording` without commit means the press
    /// cycle ended without ever crossing the hold threshold — discard.
    private var committed: Bool = false

    public init(
        backend: STTBackend,
        cleanup: CleanupPipeline,
        paster: Paster,
        appState: AppState,
        clock: WaveClock = RealClock(),
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
        case .armRecording:
            await armSession()
        case .startRecording(let reason):
            await commitSession(reason: reason)
        case .stopRecording:
            await finishSession()
        case .disarmRecording:
            await disarmSession()
        }
    }

    public func cancel() async {
        activeSession?.cancel()
        activeSession = nil
        committed = false
        appState.setStatus(.idle)
    }

    /// Open the STT session (engine starts, audio begins streaming into the
    /// session's buffer) without flipping the UI to "recording". Called on
    /// Fn-down before we know whether the press is a tap or a hold.
    private func armSession() async {
        guard activeSession == nil else { return }
        do {
            let session = try await backend.startSession()
            activeSession = session
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
    }

    /// Confirm a real recording. Engine is already running from `.armRecording`;
    /// we just flip UI state. Falls back to starting the session here if the
    /// caller skipped the arm step (keeps tests and any non-Fn entry points
    /// working).
    private func commitSession(reason: HotkeyEvent.Reason) async {
        if activeSession == nil {
            await armSession()
        }
        guard activeSession != nil else { return }
        committed = true
        appState.setStatus(.recording)
        appState.setPartial("")
        activeStartedAt = clock.now()
        _ = reason
    }

    /// Press cycle ended without becoming a hold or lock. Tear down the
    /// armed session and discard the captured audio.
    private func disarmSession() async {
        guard !committed, let session = activeSession else { return }
        session.cancel()
        activeSession = nil
    }

    private func finishSession() async {
        guard let session = activeSession else {
            appState.setStatus(.idle)
            return
        }
        activeSession = nil

        // `.stopRecording` without a prior `.startRecording` (commit) means
        // the press cycle ended in pre-roll only. Discard, don't transcribe.
        guard committed else {
            session.cancel()
            appState.setStatus(.idle)
            return
        }
        committed = false

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
