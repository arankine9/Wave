// Offline token-budget probe (project.md gate P3). Walks every
// cleanup-pair fixture, computes the input cost (system prompt plus raw
// transcript) the pipeline would charge, and asserts p95 stays at or
// under 200. The output-token bound needs a real LLM to verify so it
// isn't checked here, but a prompt edit that quietly pushes input over
// the budget fails this before it lands.

import XCTest
@testable import WaveCore

final class TokenBudgetBenchmarkTests: XCTestCase {
    func testInputTokenP95UnderTwoHundred() throws {
        let url = fixtureURL(named: "cleanup-pairs.json")
        let data = try Data(contentsOf: url)
        struct Corpus: Decodable { struct Entry: Decodable { let raw: String; let expectGateSkip: Bool }; let entries: [Entry] }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)

        let promptTokens = SystemPrompt.estimateTokens(SystemPrompt.text)
        let inputs: [Int] = corpus.entries
            .filter { !$0.expectGateSkip }
            .map { promptTokens + SystemPrompt.estimateTokens($0.raw) }

        XCTAssertGreaterThan(inputs.count, 0)
        let p95 = percentile(inputs, 0.95)
        XCTAssertLessThanOrEqual(p95, 200, "p95 input tokens \(p95) exceeds 200 budget")
    }

    private func percentile(_ values: [Int], _ p: Double) -> Int {
        let sorted = values.sorted()
        let idx = min(sorted.count - 1, Int(ceil(Double(sorted.count) * p)) - 1)
        return sorted[max(0, idx)]
    }

    private func fixtureURL(named: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent(); url.deleteLastPathComponent()
        return url.appendingPathComponent("Tests/fixtures/\(named)")
    }
}
