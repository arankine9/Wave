// DisfluencyFilter strips "um", "uh", "like" and similar words without
// eating the cases where those same words are doing real work ("I like
// the search", "feels like there's no latency"). The line between
// filler and real word is thin enough that most of the coverage lives
// here, including stutter dedup and the I-restart artifact.

import XCTest
@testable import WaveCore

final class DisfluencyFilterTests: XCTestCase {

    // MARK: - The litmus case from the user

    func testLitmusCase_likeAtStartAndMidSentence() {
        XCTAssertEqual(
            DisfluencyFilter.transform("Like it's not like deduplicating"),
            "it's not deduplicating"
        )
    }

    // MARK: - Hard fillers

    func testHardFillersStripped() {
        XCTAssertEqual(DisfluencyFilter.transform("um well I think uh we should go"), "well I think we should go")
        XCTAssertEqual(DisfluencyFilter.transform("ah, that's nice"), "that's nice")
        XCTAssertEqual(DisfluencyFilter.transform("hmm let me see"), "let me see")
    }

    // MARK: - Sentence-initial filler

    func testSentenceInitialLikeStripped() {
        XCTAssertEqual(
            DisfluencyFilter.transform("Like, the search needs to be better."),
            "the search needs to be better."
        )
    }

    func testSentenceInitialSoStripped() {
        XCTAssertEqual(
            DisfluencyFilter.transform("So, do a whole bunch of research."),
            "do a whole bunch of research."
        )
    }

    func testMidUtteranceInitialFillerAfterPeriod() {
        let raw = "I want to be sure. Like, why is it slow?"
        XCTAssertEqual(DisfluencyFilter.transform(raw), "I want to be sure. why is it slow?")
    }

    // MARK: - Comma-bounded fillers

    func testCommaBoundedLikeStripped() {
        XCTAssertEqual(
            DisfluencyFilter.transform("deduplicates words and, like, slightly cleans up"),
            "deduplicates words and, slightly cleans up"
        )
    }

    func testCommaBoundedYouKnowStripped() {
        XCTAssertEqual(
            DisfluencyFilter.transform("we could, you know, ship it tomorrow"),
            "we could, ship it tomorrow"
        )
    }

    // MARK: - Context-gated "like" — idiom protection

    func testFeelsLikeIsProtected() {
        XCTAssertEqual(
            DisfluencyFilter.transform("it feels like there's no latency"),
            "it feels like there's no latency"
        )
    }

    func testWouldLikeToIsProtected() {
        XCTAssertEqual(
            DisfluencyFilter.transform("I would like to go home"),
            "I would like to go home"
        )
    }

    func testILikeIsProtected() {
        XCTAssertEqual(DisfluencyFilter.transform("I like the search"), "I like the search")
    }

    func testSomethingLikeIsProtected() {
        XCTAssertEqual(
            DisfluencyFilter.transform("we need something like a database"),
            "we need something like a database"
        )
    }

    // MARK: - Stutter dedup

    func testBigramStutterCollapsed() {
        XCTAssertEqual(DisfluencyFilter.transform("we should we should go"), "we should go")
    }

    func testFillerRestartFullyStripped() {
        // From real history: "with like a like a neon database". The user was
        // hesitating; the right cleanup drops the entire "like a like a"
        // construct, not just one "like". Sentence-initial filler does the
        // first strip, context-gated like + stutter dedup do the rest.
        XCTAssertEqual(
            DisfluencyFilter.transform("like a like a neon database"),
            "a neon database"
        )
    }

    func testUnigramStutterCollapsed() {
        XCTAssertEqual(DisfluencyFilter.transform("the the cat sat"), "the cat sat")
    }

    func testIntensifierPreserved() {
        XCTAssertEqual(DisfluencyFilter.transform("very very good"), "very very good")
        XCTAssertEqual(DisfluencyFilter.transform("really really nice"), "really really nice")
    }

    func testTripleRepeatPreserved() {
        // Mic test from real history: "Hello, hello, hello, testing, testing, testing"
        // is deliberate. Three+ in a row should not collapse.
        let raw = "Hello, hello, hello, testing, testing, testing"
        XCTAssertEqual(DisfluencyFilter.transform(raw), raw)
    }

    func testCommaSeparatedRepeatPreserved() {
        // "No, no, I won't" — deliberate emphasis bounded by commas.
        XCTAssertEqual(DisfluencyFilter.transform("No, no, I won't"), "No, no, I won't")
    }

    // MARK: - I-restart artifact

    func testIRestartCollapsed() {
        XCTAssertEqual(DisfluencyFilter.transform("I. I like the search."), "I like the search.")
    }

    // MARK: - Sentence boundary repair

    func testMissingPeriodBeforeCueWord() {
        XCTAssertEqual(
            DisfluencyFilter.transform("research as well So do a thing"),
            "research as well. do a thing"
        )
    }

    // MARK: - Pass-through

    func testCleanProseUnchanged() {
        let clean = "I want to ship this feature today."
        XCTAssertEqual(DisfluencyFilter.transform(clean), clean)
    }

    func testEmptyAndWhitespace() {
        XCTAssertEqual(DisfluencyFilter.transform(""), "")
        XCTAssertEqual(DisfluencyFilter.transform("   "), "")
    }
}
