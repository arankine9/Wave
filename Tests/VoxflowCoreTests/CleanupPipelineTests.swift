import XCTest
@testable import VoxflowCore

final class CleanupPipelineTests: XCTestCase {
    func testGateSkipsReturnsRawAndAvoidsClient() async throws {
        let client = StubCleanupClient(chunks: ["should not be called"])
        let pipeline = CleanupPipeline(client: client, model: "stub")

        let result = try await pipeline.run(rawTranscript: "hello there")

        XCTAssertEqual(result.path, .skipped)
        XCTAssertEqual(result.text, "hello there")
        XCTAssertEqual(result.inputTokens, 0)
        XCTAssertEqual(result.outputTokens, 0)
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
