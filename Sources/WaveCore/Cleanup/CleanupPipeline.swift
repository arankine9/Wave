import Foundation

public struct CleanupResult: Sendable, Equatable {
    public enum Path: String, Sendable, Equatable { case skipped, cleaned }
    public let text: String
    public let path: Path
    public let inputTokens: Int
    public let outputTokens: Int
    public let elapsedMs: Int

    public init(text: String, path: Path, inputTokens: Int, outputTokens: Int, elapsedMs: Int) {
        self.text = text
        self.path = path
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.elapsedMs = elapsedMs
    }
}

public final class CleanupPipeline: @unchecked Sendable {
    private let client: CleanupClient
    private let model: String
    private let clock: WaveClock
    private let identityCache: IdentityCache?
    private let allowHeuristicFallback: Bool
    private let mode: CleanupMode

    public init(
        client: CleanupClient,
        model: String,
        clock: WaveClock = RealClock(),
        identityCache: IdentityCache? = nil,
        allowHeuristicFallback: Bool = true,
        mode: CleanupMode = .auto
    ) {
        self.client = client
        self.model = model
        self.clock = clock
        self.identityCache = identityCache
        self.allowHeuristicFallback = allowHeuristicFallback
        self.mode = mode
    }

    /// Runs the full cleanup decision. Three short-circuits:
    ///   1. Gate skip (short, plain text → return raw, no LLM).
    ///   2. Identity cache hit (raw has been a no-op for the LLM `threshold`
    ///      times in a row → trust it, return raw, no LLM).
    ///   3. LLM round-trip with streaming concatenation, with the cache
    ///      updated based on whether the model changed anything.
    public func run(rawTranscript: String) async throws -> CleanupResult {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = clock.now()

        // CleanupMode.off bypasses everything — user wants raw transcript.
        if mode == .off {
            return CleanupResult(
                text: trimmed, path: .skipped,
                inputTokens: 0, outputTokens: 0, elapsedMs: 0
            )
        }

        // Phase 1: always-on deterministic cleanup. Disfluency removal,
        // optional spoken-symbol substitution, spacing/casing normalization.
        // Pure Swift, <2ms, zero hallucination risk.
        let deterministic = DeterministicCleanup.transform(trimmed)

        // Heuristic-only mode stops here: the user explicitly opted out of
        // the LLM stage.
        if mode == .heuristic {
            return CleanupResult(
                text: deterministic, path: .cleaned,
                inputTokens: 0, outputTokens: SystemPrompt.estimateTokens(deterministic),
                elapsedMs: Int((clock.now() - started) * 1000)
            )
        }

        // SkipGate now runs against the already-cleaned text. If after
        // deterministic cleanup the result is short plain prose with no
        // code signals, the LLM has nothing to add — paste it as-is.
        if SkipGate.shouldSkipCleanup(deterministic) {
            return CleanupResult(
                text: deterministic, path: .cleaned,
                inputTokens: 0, outputTokens: SystemPrompt.estimateTokens(deterministic),
                elapsedMs: Int((clock.now() - started) * 1000)
            )
        }

        if let cache = identityCache, cache.shouldSkip(raw: deterministic) {
            return CleanupResult(
                text: deterministic, path: .skipped,
                inputTokens: 0, outputTokens: 0,
                elapsedMs: Int((clock.now() - started) * 1000)
            )
        }

        // Phase 2: LLM polish on the cleaned text. The LLM operates on
        // shorter, less-noisy input so it focuses on rewriting awkward
        // phrasing rather than disfluency removal.
        let inputTokens = SystemPrompt.estimateTokens(SystemPrompt.text) +
                          SystemPrompt.estimateTokens(deterministic)
        var collected = ""
        do {
            let stream = client.stream(systemPrompt: SystemPrompt.text, userText: deterministic, model: model)
            for try await chunk in stream {
                collected.append(chunk)
            }
        } catch {
            // LLM unreachable: ship the deterministic result — already a real
            // cleanup, unlike the prior behavior which fell back to raw text.
            guard allowHeuristicFallback else { throw error }
            return CleanupResult(
                text: deterministic, path: .cleaned,
                inputTokens: 0, outputTokens: SystemPrompt.estimateTokens(deterministic),
                elapsedMs: Int((clock.now() - started) * 1000)
            )
        }
        let outputTokens = SystemPrompt.estimateTokens(collected)
        let elapsedMs = Int((clock.now() - started) * 1000)
        let cleaned = collected.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cache = identityCache {
            if cleaned == deterministic {
                cache.recordIdentityPass(raw: deterministic)
            } else {
                cache.recordMutation(raw: deterministic)
            }
        }

        return CleanupResult(
            text: cleaned, path: .cleaned,
            inputTokens: inputTokens, outputTokens: outputTokens, elapsedMs: elapsedMs
        )
    }
}
