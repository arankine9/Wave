import XCTest
@testable import WaveCore

final class SpacingAndCasingTests: XCTestCase {

    // MARK: - Spacing

    func testNoSpaceBeforePunctuation() {
        XCTAssertEqual(
            SpacingAndCasing.normalizeSpacing("hello , world ."),
            "hello, world."
        )
    }

    func testNoSpaceAfterOpenBracket() {
        // Per Talon: ( glues right but space before is decided by left side.
        // "foo (x)" is correct prose; tighter "foo(x)" is a code-mode concern
        // handled by HeuristicCleanup, not this layer.
        XCTAssertEqual(
            SpacingAndCasing.normalizeSpacing("foo ( x )"),
            "foo (x)"
        )
    }

    func testHyphenJoinsTokens() {
        XCTAssertEqual(
            SpacingAndCasing.normalizeSpacing("self - drive"),
            "self-drive"
        )
    }

    // MARK: - Capitalization

    func testCapitalizesFirstSentence() {
        XCTAssertEqual(SpacingAndCasing.autoCapitalize("hello there."), "Hello there.")
    }

    func testCapitalizesAfterPeriod() {
        XCTAssertEqual(
            SpacingAndCasing.autoCapitalize("hello. world."),
            "Hello. World."
        )
    }

    func testCapitalizesAfterQuestion() {
        XCTAssertEqual(
            SpacingAndCasing.autoCapitalize("really? yes."),
            "Really? Yes."
        )
    }

    func testIeAndEgDoNotEndSentence() {
        XCTAssertEqual(
            SpacingAndCasing.autoCapitalize("see the docs, e.g. the readme."),
            "See the docs, e.g. the readme."
        )
        XCTAssertEqual(
            SpacingAndCasing.autoCapitalize("see i.e. the readme."),
            "See i.e. the readme."
        )
    }

    func testAfterNewlineCapitalizes() {
        XCTAssertEqual(
            SpacingAndCasing.autoCapitalize("first line\nsecond line"),
            "First line\nSecond line"
        )
    }

    // MARK: - Combined

    func testCombinedPipelineSpacesThenCases() {
        XCTAssertEqual(
            SpacingAndCasing.transform("hello , world . how are you ?"),
            "Hello, world. How are you?"
        )
    }
}
