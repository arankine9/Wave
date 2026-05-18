import XCTest
@testable import WaveCore

/// Fixed-budget perf gate on the orchestrator hold→paste cycle.
///
/// This is the in-process companion to `scripts/bench-latency.sh` (which
/// hits a real microphone + real Ollama and needs recorded audio
/// fixtures). The script proves end-to-end p50/p95 on a developer
/// machine; this test runs in CI on every push and catches
/// order-of-magnitude regressions in the wiring around the I/O
/// boundaries — actor hops, state-machine transitions, deterministic
/// cleanup, gate decisions, paste plumbing.
///
/// Boundaries are stubbed:
///
///   - `PerfStubBackend` returns a pre-canned transcript with no audio
///     capture.
///   - `PerfStubClient` streams pre-canned chunks with no LLM round
///     trip.
///   - `PerfSpyPaster` records the pasted string instead of touching
///     the pasteboard.
///
/// What's NOT stubbed (and therefore what the budget covers):
///
///   - The full `HotkeyController` state machine driven by `TestClock`.
///   - The real `DictationOrchestrator` actor (await hops, state writes).
///   - `CleanupPipeline.run` including `SkipGate`, `DeterministicCleanup`,
///     token estimation, and chunk concatenation.
///   - `AppState` status fan-out.
///
/// # Why a hard ceiling
///
/// `XCTClockMetric` gives Xcode users baseline tracking, but baselines
/// live in `.xcbaselines` files Xcode owns — they're not portable to
/// `swift test` on CI. So we ALSO wall-clock a single warm cycle and
/// assert it under a fixed ceiling. That ceiling is the SDET-grade
/// version of "the resume path feels snappy": if the in-process cycle
/// ever drifts above it, something architectural regressed (extra
/// actor hop, accidental sync I/O, retain cycle in the cleanup
/// pipeline, etc.) and CI fails before the bad commit lands.
///
/// # Budget rationale
///
/// `RESUME_BUDGET_MS = 184`. The number is chosen above the typical
/// observed wall-clock for this cycle on a stock M3 macOS runner
/// (single-digit milliseconds) to absorb GitHub Actions variance, GC
/// pauses, and ARC churn, while still being tight enough that a real
/// architectural regression (a sync sleep, a missed-await deadlock
/// recovery, a quadratic pass over the cleanup corpus) trips it
/// immediately. If you find yourself raising this number, **don't** —
/// the right move is to investigate what slowed down.
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
