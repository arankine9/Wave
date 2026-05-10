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
    private let clock: VoxflowClock

    public init(client: CleanupClient, model: String, clock: VoxflowClock = RealClock()) {
        self.client = client
        self.model = model
        self.clock = clock
    }

    /// Runs the full cleanup decision. If the gate says skip, returns the
    /// raw text immediately. Otherwise streams from the cleanup client and
    /// returns the concatenated final result.
    public func run(rawTranscript: String) async throws -> CleanupResult {
        let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = clock.now()

        if SkipGate.shouldSkipCleanup(trimmed) {
            return CleanupResult(
                text: trimmed,
                path: .skipped,
                inputTokens: 0,
                outputTokens: 0,
                elapsedMs: 0
            )
        }

        let inputTokens = SystemPrompt.estimateTokens(SystemPrompt.text) +
                          SystemPrompt.estimateTokens(trimmed)
        var collected = ""
        let stream = client.stream(systemPrompt: SystemPrompt.text, userText: trimmed, model: model)
        for try await chunk in stream {
            collected.append(chunk)
        }
        let outputTokens = SystemPrompt.estimateTokens(collected)
        let elapsedMs = Int((clock.now() - started) * 1000)

        let cleaned = collected.trimmingCharacters(in: .whitespacesAndNewlines)
        return CleanupResult(
            text: cleaned,
            path: .cleaned,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            elapsedMs: elapsedMs
        )
    }
}
