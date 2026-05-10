import XCTest
@testable import VoxflowCore

final class CleanupModeTests: XCTestCase {
    func testOffPathBypassesEverything() async throws {
        let pipeline = CleanupPipeline(
            client: AlwaysFailClient(),
            model: "x",
            mode: .off
        )
        let result = try await pipeline.run(rawTranscript: "open paren x close paren")
        XCTAssertEqual(result.text, "open paren x close paren")
        XCTAssertEqual(result.path, .skipped)
    }

    func testHeuristicModeUsesRegexNotLLM() async throws {
        let pipeline = CleanupPipeline(
            client: AlwaysFailClient(),
            model: "x",
            mode: .heuristic
        )
        let result = try await pipeline.run(rawTranscript: "open paren self dot id close paren")
        XCTAssertEqual(result.text, "(self.id)")
        XCTAssertEqual(result.path, .cleaned)
        XCTAssertEqual(result.inputTokens, 0,
            "heuristic mode never charges LLM input tokens")
    }

    func testAutoModeStillUsesLLMWhenAvailable() async throws {
        let client = OkClient(chunks: ["(self.id)"])
        let pipeline = CleanupPipeline(client: client, model: "x", mode: .auto)
        let result = try await pipeline.run(rawTranscript: "open paren self dot id close paren")
        XCTAssertEqual(result.text, "(self.id)")
        XCTAssertEqual(result.path, .cleaned)
        XCTAssertGreaterThan(result.inputTokens, 0)
    }

    func testEnvironmentLoaderParsesCleanupMode() {
        let prefs = Preferences.loadFromEnvironment(["VOXFLOW_CLEANUP_MODE": "heuristic"])
        XCTAssertEqual(prefs.cleanupMode, .heuristic)
    }
}

private final class AlwaysFailClient: CleanupClient, @unchecked Sendable {
    func stream(systemPrompt: String, userText: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in c.finish(throwing: CleanupError.transport("offline")) }
    }
}

private final class OkClient: CleanupClient, @unchecked Sendable {
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
