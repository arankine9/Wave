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

    /// `DeterministicCleanup` routes spoken-code dictation through
    /// `HeuristicCleanup`, so the same transform is reachable end-to-end.
    func testReachedViaDeterministicCleanup() {
        XCTAssertEqual(
            DeterministicCleanup.transform("open paren x close paren"),
            "(x)"
        )
    }
}
