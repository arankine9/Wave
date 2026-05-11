import XCTest
@testable import BeckCore

/// These tests pin SkipGate's decisions against the cleanup-pair and
/// identifier-spelling fixture corpora. The gate must skip plain prose,
/// must NOT skip code-shaped input, and must NEVER skip a letter-by-letter
/// identifier spelling (or the user loses identifier characters).
final class FixtureGateTests: XCTestCase {
    private struct CleanupCorpus: Decodable {
        struct Entry: Decodable {
            let raw: String
            let cleaned: String
            let expectGateSkip: Bool
        }
        let entries: [Entry]
    }

    private struct SpellingCorpus: Decodable {
        struct Entry: Decodable {
            let raw: String
            let expectedIdentifier: String
            let expectGateSkip: Bool
        }
        let entries: [Entry]
    }

    func testCleanupPairsFixtureGateDecisions() throws {
        let url = fixtureURL(named: "cleanup-pairs.json")
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(CleanupCorpus.self, from: data)
        XCTAssertGreaterThanOrEqual(corpus.entries.count, 30, "C6 requires ≥30 pairs")

        for entry in corpus.entries {
            let actual = SkipGate.shouldSkipCleanup(entry.raw)
            XCTAssertEqual(actual, entry.expectGateSkip,
                "gate disagreed on '\(entry.raw)': expected skip=\(entry.expectGateSkip), got skip=\(actual)")
        }
    }

    func testIdentifierSpellingFixturesNeverGateSkip() throws {
        let url = fixtureURL(named: "identifier-spelling.json")
        let data = try Data(contentsOf: url)
        let corpus = try JSONDecoder().decode(SpellingCorpus.self, from: data)
        XCTAssertGreaterThan(corpus.entries.count, 0)

        for entry in corpus.entries {
            XCTAssertFalse(entry.expectGateSkip,
                "spelling fixture '\(entry.raw)' incorrectly marked as gate-skip")
            XCTAssertFalse(SkipGate.shouldSkipCleanup(entry.raw),
                "gate would skip spelling '\(entry.raw)' — cleanup would never run, identifier lost")
        }
    }

    private func fixtureURL(named: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        // .../Tests/BeckCoreTests/FixtureGateTests.swift -> repo root
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        url.deleteLastPathComponent()
        return url.appendingPathComponent("Tests/fixtures/\(named)")
    }
}
