// Wires the production pipeline end to end: hotkey controller, then
// orchestrator, then STT, then cleanup, then paster. Stubs are at the
// audio boundary only, everything else is the real type the
// AppDelegate wires up. Drives one hold-and-release cycle per case so
// integration bugs that the per-component tests miss have somewhere to
// fail. Hotkey callbacks are sync so they get routed through a serial
// AsyncStream to keep press/release in order.

import XCTest
@testable import WaveCore

final class EndToEndIntegrationTests: XCTestCase {
    func testHoldDictateReleasePastesCleanedText() async throws {
        let backend = StubBackend(finalTranscript: "open paren self dot user underscore id close paren")
        let paster = SpyPaster()
        let appState = AppState()
        let logger = TraceCollector()
        let orchestrator = DictationOrchestrator(
            backend: backend, paster: paster,
            appState: appState, logger: logger
        )

        try await runHoldCycle(orchestrator: orchestrator)

        XCTAssertEqual(paster.pasted, ["(self.user_id)"])
        let trace = try XCTUnwrap(logger.last)
        XCTAssertEqual(trace.rawTranscript, "open paren self dot user underscore id close paren")
        XCTAssertEqual(trace.finalText, "(self.user_id)")
    }

    func testPlainProseGetsSpacingAndCasing() async throws {
        let backend = StubBackend(finalTranscript: "tomorrow morning")
        let paster = SpyPaster()
        let appState = AppState()
        let orchestrator = DictationOrchestrator(
            backend: backend, paster: paster,
            appState: appState
        )

        try await runHoldCycle(orchestrator: orchestrator)

        XCTAssertEqual(paster.pasted, ["Tomorrow morning"],
            "deterministic cleanup capitalizes the sentence start")
    }

    func testSpokenSymbolsBecomeCode() async throws {
        let backend = StubBackend(finalTranscript: "open paren x close paren")
        let paster = SpyPaster()
        let appState = AppState()
        let orchestrator = DictationOrchestrator(
            backend: backend, paster: paster,
            appState: appState
        )

        try await runHoldCycle(orchestrator: orchestrator)

        XCTAssertEqual(paster.pasted, ["(x)"])
    }

    /// Drive a full hold-and-release cycle through HotkeyController's state
    /// machine and the orchestrator, in order, then return when the
    /// orchestrator has finished pasting (or thrown).
    private func runHoldCycle(orchestrator: DictationOrchestrator) async throws {
        let clock = TestClock()
        let hotkey = HotkeyController(clock: clock, holdThresholdMs: 250, doubleTapWindowMs: 280)
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()
        hotkey.onEvent = { event in continuation.yield(event) }

        hotkey.handlePressed()
        clock.advance(by: 0.30)   // crosses hold threshold → emits .startRecording
        hotkey.handleReleased()   // emits .stopRecording
        continuation.finish()

        for await event in stream {
            await orchestrator.handle(event)
        }
    }
}

private final class StubBackend: STTBackend, @unchecked Sendable {
    let finalTranscript: String
    init(finalTranscript: String) { self.finalTranscript = finalTranscript }
    func startSession() async throws -> STTSession {
        StubSession(finalTranscript: finalTranscript)
    }
}

private final class StubSession: STTSession, @unchecked Sendable {
    let finalTranscript: String
    let partials: AsyncStream<STTPartial>
    init(finalTranscript: String) {
        self.finalTranscript = finalTranscript
        var c: AsyncStream<STTPartial>.Continuation!
        self.partials = AsyncStream { c = $0 }
        c.finish()
    }
    func finalize() async throws -> String { finalTranscript }
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
