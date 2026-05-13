import XCTest
@testable import WaveCore

final class HeuristicCleanupTests: XCTestCase {
    func testParenthesesAndDot() {
        XCTAssertEqual(
            HeuristicCleanup.transform("open paren self dot user underscore id close paren"),
            "(self.user_id)"
        )
    }

    func testNumberWords() {
        XCTAssertEqual(HeuristicCleanup.transform("let x equals five"), "let x = 5")
    }

    func testIdentifierSpellingJoinsWithUnderscore() {
        XCTAssertEqual(
            HeuristicCleanup.transform("u s e r underscore i d"),
            "user_id"
        )
    }

    func testKeywordSubstringIsLeftAlone() {
        XCTAssertEqual(HeuristicCleanup.transform("doting parents"), "doting parents")
    }

    func testFatArrow() {
        XCTAssertEqual(
            HeuristicCleanup.transform("event fat arrow handle event"),
            "event => handle event"
        )
    }

    func testFallbackPathInPipelineWhenClientThrows() async throws {
        let throwing = ThrowingClient()
        let pipeline = CleanupPipeline(client: throwing, model: "ignored", allowHeuristicFallback: true)
        let result = try await pipeline.run(rawTranscript: "open paren x close paren")
        XCTAssertEqual(result.text, "(x)")
        XCTAssertEqual(result.path, .cleaned)
        XCTAssertEqual(result.inputTokens, 0,
            "no LLM was called so input tokens stay at zero")
    }

    func testDisabledFallbackPropagatesError() async {
        let throwing = ThrowingClient()
        let pipeline = CleanupPipeline(client: throwing, model: "ignored", allowHeuristicFallback: false)
        do {
            _ = try await pipeline.run(rawTranscript: "open paren x close paren")
            XCTFail("expected throw")
        } catch let err as CleanupError {
            XCTAssertEqual(err, .transport("no server"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private final class ThrowingClient: CleanupClient, @unchecked Sendable {
    func stream(systemPrompt: String, userText: String, model: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { c in
            c.finish(throwing: CleanupError.transport("no server"))
        }
    }
}
