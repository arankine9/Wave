import XCTest
@testable import VoxflowCore

final class SystemPromptTests: XCTestCase {
    func testWithinBudget() {
        let count = SystemPrompt.estimateTokens(SystemPrompt.text)
        XCTAssertLessThanOrEqual(count, SystemPrompt.tokenBudget,
            "system prompt is \(count) tokens, budget is \(SystemPrompt.tokenBudget)")
    }

    func testEstimatorIsMonotonic() {
        let a = SystemPrompt.estimateTokens("hello")
        let b = SystemPrompt.estimateTokens("hello world goodbye")
        XCTAssertLessThan(a, b)
    }

    func testAssertWithinBudgetDoesNotCrash() {
        SystemPrompt.assertWithinBudget()
    }
}
