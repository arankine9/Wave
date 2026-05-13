import XCTest
@testable import WaveCore

final class SkipGateTests: XCTestCase {
    func testShortPlainProseSkips() {
        XCTAssertTrue(SkipGate.shouldSkipCleanup("hello there"))
        XCTAssertTrue(SkipGate.shouldSkipCleanup("send it tomorrow"))
        XCTAssertTrue(SkipGate.shouldSkipCleanup("yes that works."))
    }

    func testEmptyOrWhitespaceSkips() {
        XCTAssertTrue(SkipGate.shouldSkipCleanup(""))
        XCTAssertTrue(SkipGate.shouldSkipCleanup("   "))
    }

    func testCodeKeywordsTriggerCleanup() {
        XCTAssertFalse(SkipGate.shouldSkipCleanup("open paren self dot id close paren"))
        XCTAssertFalse(SkipGate.shouldSkipCleanup("function add a b return a plus b"))
        XCTAssertFalse(SkipGate.shouldSkipCleanup("if user underscore id equals null"))
    }

    func testCodeKeywordsAreCaseInsensitive() {
        XCTAssertFalse(SkipGate.shouldSkipCleanup("Open Paren x Close Paren"))
    }

    func testNonAllowedCharactersTriggerCleanup() {
        XCTAssertFalse(SkipGate.shouldSkipCleanup("x = 5"))
        XCTAssertFalse(SkipGate.shouldSkipCleanup("self.user_id"))
        XCTAssertFalse(SkipGate.shouldSkipCleanup("foo()"))
    }

    func testLongInputTriggersCleanup() {
        let long = String(repeating: "lorem ipsum ", count: 10)
        XCTAssertFalse(SkipGate.shouldSkipCleanup(long))
    }

    func testKeywordSubstringInsideWordDoesNotTrigger() {
        // 'doting' contains 'dot' as a substring but is a real word, not the
        // spoken keyword. Token-based matching avoids the false trigger.
        XCTAssertTrue(SkipGate.shouldSkipCleanup("doting parents"))
    }
}
