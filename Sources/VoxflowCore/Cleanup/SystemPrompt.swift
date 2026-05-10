import Foundation

/// The cleanup model's system prompt. Hard cap: 150 tokens (project.md
/// rule 2 of the token-efficiency rules). The string is short, imperative,
/// and deliberately repeats nothing the gate already catches.
public enum SystemPrompt {
    public static let text: String = """
    You convert spoken coding dictation to clean text or code.
    Rules:
    1. Output only the cleaned result. No prose, no explanations.
    2. Preserve every identifier the user spelled out letter by letter.
    3. Translate spoken punctuation to symbols (paren -> (, dot -> ., equals -> =).
    4. Drop fillers (uh, um, you know).
    5. Honor self-corrections: if the user said "no wait", drop the prior phrase.
    6. Match the user's apparent language unless told otherwise.
    """

    public static let tokenBudget = 150

    /// Rough token estimator: ceiling(chars / 4). Aligns with OpenAI's rule of
    /// thumb for English. Good enough for a budget ceiling check; if we ever
    /// add a real tokenizer we can swap this without touching call sites.
    public static func estimateTokens(_ s: String) -> Int {
        let chars = s.utf8.count
        return Int(ceil(Double(chars) / 4.0))
    }

    /// Asserts the system prompt fits the budget. Call at startup so the app
    /// fails to launch if a future edit breaks the contract.
    public static func assertWithinBudget() {
        let count = estimateTokens(text)
        precondition(
            count <= tokenBudget,
            "SystemPrompt exceeds budget: \(count) tokens > \(tokenBudget)"
        )
    }
}
