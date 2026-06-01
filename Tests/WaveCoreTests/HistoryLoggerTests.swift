import XCTest
@testable import WaveCore

final class HistoryLoggerTests: XCTestCase {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wave-history-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.jsonl")
    }

    func testRecordAndReadBack() throws {
        let url = tempFile()
        let logger = HistoryLogger(file: url)
        var trace = DictationTrace()
        trace.rawTranscript = "self dot user underscore id"
        trace.finalText = "self.user_id"
        trace.sttMs = 120
        trace.cleanupMs = 200
        trace.pasteMs = 8
        logger.record(trace)

        // Sync flush by waiting on the same queue.
        let exp = expectation(description: "flush")
        DispatchQueue(label: "drain").async {
            // The logger uses a private serial queue; round-tripping through
            // `recent` after a brief sleep is good enough for a unit test.
            Thread.sleep(forTimeInterval: 0.1)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 1.0)

        let recent = logger.recent(limit: 10)
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.finalText, "self.user_id")
        XCTAssertEqual(recent.first?.rawTranscript, "self dot user underscore id")
        XCTAssertEqual(recent.first?.cleanupMs, 200)
    }

    func testRecentRespectsLimit() {
        let url = tempFile()
        let logger = HistoryLogger(file: url)
        for i in 0..<5 {
            var trace = DictationTrace()
            trace.finalText = "entry-\(i)"
            logger.record(trace)
        }
        Thread.sleep(forTimeInterval: 0.15)
        let recent = logger.recent(limit: 3)
        XCTAssertEqual(recent.count, 3)
        XCTAssertEqual(recent.last?.finalText, "entry-4")
    }
}
