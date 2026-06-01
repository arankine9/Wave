// In-process companion to scripts/bench-latency.sh. The shell script
// hits a real mic and a real Ollama with recorded audio fixtures and
// proves end-to-end p50/p95 on a dev machine. This one stubs both
// boundaries and runs in CI on every push, so order-of-magnitude
// regressions in the wiring (actor hops, state machine, cleanup
// pipeline, paste plumbing) fail before they land.
//
// Budget is 184ms. Picked above typical wall-clock on a stock M3 runner
// to absorb CI variance, tight enough that a real regression trips it
// immediately. If you find yourself raising it, don't. Go look at what
// slowed down.

import XCTest
@testable import WaveCore

final class LatencyBudgetBenchmarkTests: XCTestCase {

    /// Fixed-budget ceiling enforced by `testResumeCycleUnderBudget`.
    /// Picked above typical observed wall-clock on a stock CI runner so
    /// transient variance doesn't flake the test, while still catching
    /// order-of-magnitude regressions.
    private static let RESUME_BUDGET_MS: Double = 184

    /// Fixed-budget assertion. Drives one warm hold→paste cycle and
    /// fails if the wall-clock exceeds `RESUME_BUDGET_MS`. Run twice;
    /// the first cycle absorbs one-shot allocations (actor creation,
    /// system prompt token-count cache priming, etc.) and the second
    /// is what we judge.
    func testResumeCycleUnderBudget() async throws {
        let warm = try await Self.runOneCycle()
        XCTAssertEqual(warm, "self.user_id = 5", "warmup cycle must take the cleaned path")

        let started = Date()
        let pasted = try await Self.runOneCycle()
        let elapsedMs = Date().timeIntervalSince(started) * 1000

        XCTAssertEqual(pasted, "self.user_id = 5",
                       "perf cycle must take the cleaned path or the budget isn't measuring the right thing")
        XCTAssertLessThan(
            elapsedMs,
            Self.RESUME_BUDGET_MS,
            "orchestrator hold→paste cycle took \(Int(elapsedMs))ms — budget is \(Int(Self.RESUME_BUDGET_MS))ms. " +
            "This is the in-process resume path; if it regressed, suspect an extra actor hop, a sync I/O leak, " +
            "a quadratic pass in CleanupPipeline, or a missed-await in DictationOrchestrator."
        )
    }

    /// XCTest `measure` block for Xcode users — records baselines that
    /// Xcode can diff against in detail on regression. CI uses the
    /// `testResumeCycleUnderBudget` ceiling above, but this gives a
    /// nicer signal when iterating in Xcode.
    func testResumeCycleBaseline() throws {
        let options = XCTMeasureOptions()
        options.iterationCount = 5

        measure(metrics: [XCTClockMetric()], options: options) {
            Self.runOneCycleSync()
        }
    }

    /// Drive one full Fn-down → Fn-hold → Fn-release cycle through the
    /// production `HotkeyController` state machine and the real
    /// `DictationOrchestrator` actor. Returns the pasted string so
    /// callers can assert the cleaned path was taken. Mirrors what
    /// `EndToEndIntegrationTests.runHoldCycle` does, deliberately —
    /// the perf gate is on the same code path the E2E correctness
    /// tests cover.
    nonisolated static func runOneCycle() async throws -> String {
        let backend = PerfStubBackend(finalTranscript: "self dot user underscore id equals five")
        let client = PerfStubClient(chunks: ["self.user_id = 5"])
        let pipeline = CleanupPipeline(client: client, model: "stub")
        let paster = PerfSpyPaster()
        let appState = AppState()
        let orchestrator = DictationOrchestrator(
            backend: backend, cleanup: pipeline, paster: paster,
            appState: appState
        )

        let clock = TestClock()
        let hotkey = HotkeyController(clock: clock, holdThresholdMs: 250, doubleTapWindowMs: 280)
        let (stream, continuation) = AsyncStream<HotkeyEvent>.makeStream()
        hotkey.onEvent = { event in continuation.yield(event) }

        hotkey.handlePressed()
        clock.advance(by: 0.30)
        hotkey.handleReleased()
        continuation.finish()

        for await event in stream {
            await orchestrator.handle(event)
        }

        return paster.pasted.last ?? ""
    }

    /// Sync bridge for the `measure {}` block, which can't take an
    /// async closure. A semaphore is the simplest safe wrapper here —
    /// the detached task captures nothing from the surrounding test
    /// case, so there's no isolation conflict.
    private static func runOneCycleSync() {
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await runOneCycle()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

// MARK: - perf-test stubs
//
// Duplicated from EndToEndIntegrationTests rather than shared because
// the test target lacks a separate helpers module and file-private
// types can't cross files. Keeping these inline also keeps the perf
// test self-contained — its budget should be readable without
// grepping for what the stubs do.

private final class PerfStubBackend: STTBackend, @unchecked Sendable {
    let finalTranscript: String
    init(finalTranscript: String) { self.finalTranscript = finalTranscript }
    func startSession() async throws -> STTSession {
        PerfStubSession(finalTranscript: finalTranscript)
    }
}

private final class PerfStubSession: STTSession, @unchecked Sendable {
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

private final class PerfStubClient: CleanupClient, @unchecked Sendable {
    private let chunks: [String]
    init(chunks: [String]) { self.chunks = chunks }
    func stream(systemPrompt: String, userText: String, model: String) -> AsyncThrowingStream<String, Error> {
        let chunks = self.chunks
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish()
        }
    }
}

private final class PerfSpyPaster: Paster, @unchecked Sendable {
    private let lock = NSLock()
    private var _pasted: [String] = []
    var pasted: [String] { lock.withLock { _pasted } }
    func paste(_ text: String) throws { lock.withLock { _pasted.append(text) } }
}
