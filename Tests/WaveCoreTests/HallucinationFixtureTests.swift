// Structural check on the hallucination audit JSON. The actual "did the
// model invent tokens" check needs a real LLM and runs in bench-judge.sh
// against Ollama. This just guards the corpus shape so a malformed
// fixture can't make that judge run silently pass.

import XCTest
@testable import WaveCore

final class HallucinationFixtureTests: XCTestCase {
    func testFixtureLoadsAndIsWellFormed() throws {
        let url = fixtureURL(named: "hallucination-audit.json")
        let data = try Data(contentsOf: url)
        struct Corpus: Decodable {
            struct Entry: Decodable { let raw: String; let mustNotContain: [String] }
            let entries: [Entry]
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        XCTAssertGreaterThanOrEqual(corpus.entries.count, 10, "Q2 fixture should ship ≥10 entries")
        for entry in corpus.entries {
            XCTAssertFalse(entry.raw.isEmpty)
            XCTAssertFalse(entry.mustNotContain.isEmpty)
            for forbidden in entry.mustNotContain {
                XCTAssertFalse(forbidden.isEmpty,
                    "must-not-contain entry for '\(entry.raw)' is empty")
            }
        }
    }

    private func fixtureURL(named: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent(); url.deleteLastPathComponent()
        return url.appendingPathComponent("Tests/fixtures/\(named)")
    }
}
