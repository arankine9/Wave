import XCTest
@testable import WaveCore

final class DictationOrchestratorTests: XCTestCase {
    func testHoldCycleProducesPasteAndTrace() async throws {
        let backend = MockSTTBackend(finalText: "self.user_id = 5")
        let client = StubCleanupClient(chunks: ["self.user_id = 5"])
        let pipeline = CleanupPipeline(client: client, model: "stub")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()
        let states = StateCollector()
        appState.onStatusChange = { status in states.append(status) }

        let orch = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
            paster: paster,
            appState: appState,
            logger: logger
        )

        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)

        XCTAssertEqual(paster.pasted, ["self.user_id = 5"])
        let trace = try XCTUnwrap(logger.last)
        XCTAssertEqual(trace.finalText, "self.user_id = 5")
        XCTAssertEqual(trace.path, .cleaned)
        XCTAssertGreaterThan(trace.inputTokens, 0)

        let observed = states.snapshot
        XCTAssertEqual(observed.first, .recording)
        XCTAssertEqual(observed.last, .idle)
        XCTAssertTrue(observed.contains(.transcribing))
        XCTAssertTrue(observed.contains(.cleaning))
        XCTAssertTrue(observed.contains(.pasting))
    }

    func testGateSkipPathPastesRaw() async throws {
        let backend = MockSTTBackend(finalText: "hello there")
        let client = StubCleanupClient(chunks: ["should not be called"])
        let pipeline = CleanupPipeline(client: client, model: "stub")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()

        let orch = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
            paster: paster,
            appState: appState,
            logger: logger
        )

        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)

        XCTAssertEqual(paster.pasted, ["hello there"])
        XCTAssertEqual(logger.last?.path, .skipped)
        XCTAssertEqual(client.callCount, 0)
    }

    func testArmCommitStopPastesAndTraces() async throws {
        let backend = MockSTTBackend(finalText: "hello world")
        let pipeline = CleanupPipeline(client: StubCleanupClient(), model: "stub")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()

        let orch = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
            paster: paster,
            appState: appState,
            logger: logger
        )

        // Pre-arm on Fn-down, commit on hold-threshold, stop on release.
        await orch.handle(.armRecording)
        await orch.handle(.startRecording(reason: .hold))
        await orch.handle(.stopRecording)

        XCTAssertEqual(backend.sessionsStarted, 1, "armRecording opens exactly one session")
        XCTAssertEqual(paster.pasted, ["hello world"])
        XCTAssertEqual(logger.last?.finalText, "hello world")
    }

    func testArmThenDisarmDiscardsSession() async {
        let backend = MockSTTBackend(finalText: "should not appear")
        let pipeline = CleanupPipeline(client: StubCleanupClient(), model: "stub")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()

        let orch = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
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
        let pipeline = CleanupPipeline(client: StubCleanupClient(), model: "stub")
        let paster = SpyPaster()
        let appState = AppState()

        let orch = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
            paster: paster,
            appState: appState
        )

        await orch.handle(.stopRecording)
        XCTAssertEqual(paster.pasted, [])
        XCTAssertEqual(appState.status, .idle)
    }

    func testEmptyFinalTranscriptSkipsPaste() async {
        let backend = MockSTTBackend(finalText: "")
        let pipeline = CleanupPipeline(client: StubCleanupClient(), model: "stub")
        let paster = SpyPaster()
        let appState = AppState()
        let orch = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
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

private final class StubCleanupClient: CleanupClient, @unchecked Sendable {
    private let chunks: [String]
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(chunks: [String] = []) { self.chunks = chunks }

    func stream(systemPrompt: String, userText: String, model: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _callCount += 1 }
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for c in chunks { continuation.yield(c) }
            continuation.finish()
        }
    }
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

private final class StateCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [DictationStatus] = []
    var snapshot: [DictationStatus] { lock.withLock { states } }
    func append(_ status: DictationStatus) { lock.withLock { states.append(status) } }
}
