// Runs DeterministicCleanup against my actual dictation history and dumps
// a before/after report to /tmp/wave_cleanup_report.txt. Not a hard
// pass/fail, more of an inspection tool when I'm tuning the rules against
// real data. Plus a few targeted asserts for patterns that kept showing
// up in the log. No-op if the history file isn't there so CI doesn't
// break for anyone else.

import XCTest
@testable import WaveCore

final class HistoryGoldenTests: XCTestCase {

    func testGenerateBeforeAfterReport() throws {
        let url = historyURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[HistoryGoldenTests] skipping: \(url.path) does not exist")
            return
        }

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(whereSeparator: { $0 == "\n" })
        var report = "# Wave deterministic cleanup — before/after\n\n"
        report += "Source: \(url.path)\n"
        report += "Entries: \(lines.count)\n\n"

        var changedCount = 0
        let decoder = JSONDecoder()
        for line in lines {
            guard let data = String(line).data(using: .utf8),
                  let entry = try? decoder.decode(HistoryLine.self, from: data) else {
                continue
            }
            let raw = entry.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let cleaned = DeterministicCleanup.transform(raw)
            let marker = cleaned == raw ? "  " : "* "
            if cleaned != raw { changedCount += 1 }
            report += "\(marker)RAW: \(raw)\n"
            report += "\(marker)CLN: \(cleaned)\n\n"
        }
        report = report.replacingOccurrences(of: "Entries: ",
                                             with: "Entries: \(changedCount) changed of ")

        let out = URL(fileURLWithPath: "/tmp/wave_cleanup_report.txt")
        try report.write(to: out, atomically: true, encoding: .utf8)
        print("[HistoryGoldenTests] wrote report → \(out.path)")
    }

    // MARK: - Targeted assertions on patterns observed in real history

    func testRealLitmus_likeFollowedByGerundAtStart() {
        // From the user's prompt verbatim.
        XCTAssertEqual(
            DeterministicCleanup.transform("Like it's not like deduplicating"),
            "It's not deduplicating"
        )
    }

    func testRealLogPattern_iRestartFollowedByLike() {
        // From history: "I. I like the search. I think that's mildly interesting."
        let raw = "I. I like the search."
        XCTAssertEqual(DeterministicCleanup.transform(raw), "I like the search.")
    }

    func testRealLogPattern_commaBoundedLike() {
        // From history: "deduplicates words and, like, slightly cleans up your messy sentences"
        let raw = "deduplicates words and, like, slightly cleans up your messy sentences"
        let cleaned = DeterministicCleanup.transform(raw)
        XCTAssertFalse(cleaned.contains(", like,"), "got: \(cleaned)")
    }

    func testRealLogPattern_intentionalTestNotMangled() {
        // From history mic-test entry. Must NOT collapse the triple repeats.
        let raw = "Hello, hello, hello, testing, testing, testing, hello, testing, testing"
        let cleaned = DeterministicCleanup.transform(raw)
        // At least one "hello" triple intact.
        XCTAssertTrue(cleaned.lowercased().contains("hello, hello, hello"),
                      "got: \(cleaned)")
    }

    private func historyURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["WAVE_HISTORY_FILE"] {
            return URL(fileURLWithPath: override)
        }
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
        return support.appendingPathComponent("Wave/history.jsonl")
    }
}
