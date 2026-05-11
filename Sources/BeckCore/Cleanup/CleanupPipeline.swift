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
    private let clock: BeckClock
    private let identityCache: IdentityCache?
    private let allowHeuristicFallback: Bool
    private let mode: CleanupMode

    public init(
        client: CleanupClient,
        model: String,
        clock: BeckClock = RealClock(),
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

        if mode == .off {
            return CleanupResult(
                text: trimmed, path: .skipped,
                inputTokens: 0, outputTokens: 0, elapsedMs: 0
            )
        }

        if mode == .heuristic {
            let heuristic = HeuristicCleanup.transform(trimmed)
            return CleanupResult(
                text: heuristic, path: .cleaned,
                inputTokens: 0, outputTokens: SystemPrompt.estimateTokens(heuristic),
                elapsedMs: Int((clock.now() - started) * 1000)
            )
        }

        if SkipGate.shouldSkipCleanup(trimmed) {
            return CleanupResult(
                text: trimmed, path: .skipped,
                inputTokens: 0, outputTokens: 0, elapsedMs: 0
            )
        }

        if let cache = identityCache, cache.shouldSkip(raw: trimmed) {
            return CleanupResult(
                text: trimmed, path: .skipped,
                inputTokens: 0, outputTokens: 0,
                elapsedMs: Int((clock.now() - started) * 1000)
            )
        }

        let inputTokens = SystemPrompt.estimateTokens(SystemPrompt.text) +
                          SystemPrompt.estimateTokens(trimmed)
        var collected = ""
        do {
            let stream = client.stream(systemPrompt: SystemPrompt.text, userText: trimmed, model: model)
            for try await chunk in stream {
                collected.append(chunk)
            }
        } catch {
            // No LLM reachable. Fall back to the offline heuristic cleanup so
            // the user still gets code-shaped output instead of "open paren".
            guard allowHeuristicFallback else { throw error }
            let heuristic = HeuristicCleanup.transform(trimmed)
            return CleanupResult(
                text: heuristic, path: .cleaned,
                inputTokens: 0, outputTokens: SystemPrompt.estimateTokens(heuristic),
                elapsedMs: Int((clock.now() - started) * 1000)
            )
        }
        let outputTokens = SystemPrompt.estimateTokens(collected)
        let elapsedMs = Int((clock.now() - started) * 1000)
        let cleaned = collected.trimmingCharacters(in: .whitespacesAndNewlines)

        if let cache = identityCache {
            if cleaned == trimmed {
                cache.recordIdentityPass(raw: trimmed)
            } else {
                cache.recordMutation(raw: trimmed)
            }
        }

        return CleanupResult(
            text: cleaned, path: .cleaned,
            inputTokens: inputTokens, outputTokens: outputTokens, elapsedMs: elapsedMs
        )
    }
}
