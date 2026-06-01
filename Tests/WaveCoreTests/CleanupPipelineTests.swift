// CleanupPipeline chains the gate, deterministic cleanup, and the LLM
// call together. Covers the three branches: gate-skip with no LLM hit,
// code-shaped input that does call the LLM and concatenates streamed
// chunks, and client error propagation when heuristic fallback is off.

import XCTest
@testable import WaveCore

final class CleanupPipelineTests: XCTestCase {
    func testGateSkipsLLMForPlainProse() async throws {
        // Plain short prose passes deterministic cleanup (capitalization)
        // but skips the LLM. Result is the cleaned text with `cleaned` path
        // and zero input tokens because no LLM call was made.
        let client = StubCleanupClient(chunks: ["should not be called"])
        let pipeline = CleanupPipeline(client: client, model: "stub")

        let result = try await pipeline.run(rawTranscript: "hello there")

        XCTAssertEqual(result.path, .cleaned)
        XCTAssertEqual(result.text, "Hello there")
        XCTAssertEqual(result.inputTokens, 0, "no LLM call → zero input tokens")
        XCTAssertEqual(client.callCount, 0)
    }

    func testCodeInputCallsClientAndConcatenatesChunks() async throws {
        let client = StubCleanupClient(chunks: ["self.user", "_id = ", "5"])
        let pipeline = CleanupPipeline(client: client, model: "stub")

        let result = try await pipeline.run(rawTranscript: "self dot user underscore id equals five")

        XCTAssertEqual(result.path, .cleaned)
        XCTAssertEqual(result.text, "self.user_id = 5")
        XCTAssertGreaterThan(result.inputTokens, 0)
        XCTAssertGreaterThan(result.outputTokens, 0)
        XCTAssertEqual(client.callCount, 1)
    }

    func testClientErrorPropagatesWhenFallbackDisabled() async {
        let client = StubCleanupClient(error: CleanupError.modelMissing("nope"))
        let pipeline = CleanupPipeline(client: client, model: "nope", allowHeuristicFallback: false)

        do {
            _ = try await pipeline.run(rawTranscript: "open paren x close paren")
            XCTFail("expected throw")
        } catch let err as CleanupError {
            XCTAssertEqual(err, .modelMissing("nope"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private final class StubCleanupClient: CleanupClient, @unchecked Sendable {
    private let chunks: [String]
    private let error: CleanupError?
    private let lock = NSLock()
    private var _callCount = 0
    var callCount: Int { lock.withLock { _callCount } }

    init(chunks: [String] = [], error: CleanupError? = nil) {
        self.chunks = chunks
        self.error = error
    }

    func stream(systemPrompt: String, userText: String, model: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _callCount += 1 }
        let chunks = self.chunks
        let error = self.error
        return AsyncThrowingStream { continuation in
            if let error {
                continuation.finish(throwing: error)
                return
            }
            for c in chunks { continuation.yield(c) }
            continuation.finish()
        }
    }
}
