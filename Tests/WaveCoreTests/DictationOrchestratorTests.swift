import XCTest
@testable import WaveCore

final class DictationOrchestratorTests: XCTestCase {
    func testHoldCycleProducesPasteAndTrace() async throws {
        let backend = MockSTTBackend(finalText: "hold cycle works")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()
        let states = StateCollector()
        appState.onStatusChange = { status in states.append(status) }

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            logger: logger
        )

        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)

        // Deterministic cleanup capitalizes the sentence start.
        XCTAssertEqual(paster.pasted, ["Hold cycle works"])
        let trace = try XCTUnwrap(logger.last)
        XCTAssertEqual(trace.finalText, "Hold cycle works")
        XCTAssertEqual(trace.rawTranscript, "hold cycle works")

        let observed = states.snapshot
        XCTAssertEqual(observed.first, .recording)
        XCTAssertEqual(observed.last, .idle)
        XCTAssertTrue(observed.contains(.transcribing))
        XCTAssertTrue(observed.contains(.cleaning))
        XCTAssertTrue(observed.contains(.pasting))
    }

    func testPlainProseIsDeterministicallyCleaned() async throws {
        let backend = MockSTTBackend(finalText: "hello there")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            logger: logger
        )

        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)

        XCTAssertEqual(paster.pasted, ["Hello there"])
    }

    func testSpokenCodeIsDeterministicallyCleaned() async throws {
        let backend = MockSTTBackend(finalText: "open paren self dot user underscore id close paren")
        let paster = SpyPaster()
        let appState = AppState()

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState
        )

        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)

        XCTAssertEqual(paster.pasted, ["(self.user_id)"])
    }

    func testArmCommitStopPastesAndTraces() async throws {
        let backend = MockSTTBackend(finalText: "hello world")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            logger: logger
        )

        // Pre-arm on Fn-down, commit on hold-threshold, stop on release.
        await orch.handle(.armRecording)
        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)

        XCTAssertEqual(backend.sessionsStarted, 1, "armRecording opens exactly one session")
        XCTAssertEqual(paster.pasted, ["Hello world"])
        XCTAssertEqual(logger.last?.finalText, "Hello world")
    }

    func testArmThenDisarmDiscardsSession() async {
        let backend = MockSTTBackend(finalText: "should not appear")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            logger: logger
        )

        // Single tap: arm, then disarm without ever committing.
        await orch.handle(.armRecording)
        await orch.handle(.disarmRecording)

        XCTAssertEqual(backend.sessionsStarted, 1)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertNil(logger.last)
        XCTAssertEqual(appState.status, .idle)
    }

    func testStopWithoutStartIsNoop() async {
        let backend = MockSTTBackend(finalText: "")
        let paster = SpyPaster()
        let appState = AppState()

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState
        )

        await orch.handle(.stopRecording)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(appState.status, .idle)
    }

    func testMediaPausesOnRecordAndResumesOnStop() async {
        let backend = MockSTTBackend(finalText: "hello")
        let paster = SpyPaster()
        let appState = AppState()
        let media = SpyMediaController(playing: true)

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            media: media,
            mediaMuteEnabled: { true }
        )

        await orch.handle(.startRecording(reason: .hold))
        XCTAssertEqual(media.pauseCalls, 1)
        XCTAssertEqual(media.resumeCalls, 0)

        await orch.handle(.stopRecording)
        XCTAssertEqual(media.pauseCalls, 1)
        XCTAssertEqual(media.resumeCalls, 1)
    }

    func testMediaDoesNotResumeWhenNothingWasPlaying() async {
        let backend = MockSTTBackend(finalText: "hello")
        let paster = SpyPaster()
        let appState = AppState()
        let media = SpyMediaController(playing: false)

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            media: media,
            mediaMuteEnabled: { true }
        )

        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)
        XCTAssertEqual(media.pauseCalls, 1)
        XCTAssertEqual(media.resumeCalls, 0,
            "no resume should fire if nothing was playing when we tried to pause")
    }

    func testMediaIsLeftAloneWhenPreferenceIsOff() async {
        let backend = MockSTTBackend(finalText: "hello")
        let paster = SpyPaster()
        let appState = AppState()
        let media = SpyMediaController(playing: true)

        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            media: media,
            mediaMuteEnabled: { false }
        )

        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)
        XCTAssertEqual(media.pauseCalls, 0)
        XCTAssertEqual(media.resumeCalls, 0)
    }

    func testEmptyFinalTranscriptSkipsPaste() async {
        let backend = MockSTTBackend(finalText: "")
        let paster = SpyPaster()
        let appState = AppState()
        let orch = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState
        )

        await orch.handle(.startRecording(reason: .locked))
        await orch.handle(.stopRecording)

        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(appState.status, .idle)
    }
}

// MARK: - Mocks

private final class MockSTTBackend: STTBackend, @unchecked Sendable {
    let finalText: String
    private let lock = NSLock()
    private var _sessionsStarted = 0
    var sessionsStarted: Int { lock.withLock { _sessionsStarted } }
    init(finalText: String) { self.finalText = finalText }
    func startSession() async throws -> STTSession {
        lock.withLock { _sessionsStarted += 1 }
        return MockSTTSession(finalText: finalText)
    }
}

private final class MockSTTSession: STTSession, @unchecked Sendable {
    let finalText: String
    let partials: AsyncStream<STTPartial>
    init(finalText: String) {
        self.finalText = finalText
        var c: AsyncStream<STTPartial>.Continuation!
        self.partials = AsyncStream { c = $0 }
        c.finish()
    }
    func finalize() async throws -> String { finalText }
    func cancel() {}
}

private final class SpyPaster: Paster, @unchecked Sendable {
    private let lock = NSLock()
    private var _pasted: [String] = []
    var pasted: [String] { lock.withLock { _pasted } }
    func paste(_ text: String) throws { lock.withLock { _pasted.append(text) } }
}

private final class TraceCollector: DictationLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var traces: [DictationTrace] = []
    var last: DictationTrace? { lock.withLock { traces.last } }
    func record(_ trace: DictationTrace) { lock.withLock { traces.append(trace) } }
}

private final class SpyMediaController: MediaController, @unchecked Sendable {
    private let lock = NSLock()
    private var _playing: Bool
    private var _pauseCalls = 0
    private var _resumeCalls = 0
    var pauseCalls: Int { lock.withLock { _pauseCalls } }
    var resumeCalls: Int { lock.withLock { _resumeCalls } }

    init(playing: Bool) { self._playing = playing }

    func pauseIfPlaying() async -> Bool {
        lock.withLock {
            _pauseCalls += 1
            guard _playing else { return false }
            _playing = false
            return true
        }
    }

    func resume() async {
        lock.withLock { _resumeCalls += 1 }
    }
}

private final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [DictationStatus] = []
    var snapshot: [DictationStatus] { lock.withLock { states } }
    func append(_ status: DictationStatus) { lock.withLock { states.append(status) } }
}
