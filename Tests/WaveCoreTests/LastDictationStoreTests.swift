// The repaste hotkey re-pastes "the last dictation", so the store behind it
// has to track the most recent *non-empty* finalText: empty utterances are
// still logged to history but must not wipe what Ctrl+Cmd+V would paste.

import XCTest
@testable import WaveCore

final class LastDictationStoreTests: XCTestCase {
    func testStartsEmpty() {
        XCTAssertNil(LastDictationStore().text)
    }

    func testSeededValueIsAvailableImmediately() {
        XCTAssertEqual(LastDictationStore(text: "from history").text, "from history")
    }

    func testRecordsLatestFinalText() {
        let store = LastDictationStore()
        store.record(trace(final: "hello world"))
        XCTAssertEqual(store.text, "hello world")
        store.record(trace(final: "second one"))
        XCTAssertEqual(store.text, "second one")
    }

    func testEmptyFinalTextDoesNotOverwrite() {
        let store = LastDictationStore(text: "keep me")
        store.record(trace(final: ""))
        XCTAssertEqual(store.text, "keep me")
    }

    func testCompositeFansOutToEveryLogger() {
        let store = LastDictationStore()
        let spy = RecordingSpy()
        let composite = CompositeDictationLogger([store, spy])

        composite.record(trace(final: "fanned out"))

        XCTAssertEqual(store.text, "fanned out")
        XCTAssertEqual(spy.count, 1)
    }

    private func trace(final: String) -> DictationTrace {
        var t = DictationTrace()
        t.finalText = final
        return t
    }
}

private final class RecordingSpy: DictationLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func record(_ trace: DictationTrace) { lock.withLock { _count += 1 } }
}
