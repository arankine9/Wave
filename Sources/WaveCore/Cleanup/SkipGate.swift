import Foundation

/// Classifies a transcript as code dictation vs. plain prose so
/// `DeterministicCleanup` knows whether to run the spoken-symbol substitution
/// pass (`HeuristicCleanup`) or the prose spacing/casing pass.
public enum SkipGate {
    /// Unambiguous spoken-code tokens that avoid common English words ("if",
    /// "return", "class", "let", "function") which would falsely flag prose as
    /// code. Used by `looksLikeCodeDictation`.
    private static let strongCodeKeywords: Set<String> = [
        "paren", "parens", "parenthesis",
        "bracket", "brackets",
        "brace", "braces", "curly",
        "underscore",
        "semicolon",
        "backslash", "backtick",
        "ampersand", "caret", "asterisk", "tilde",
        "newline", "indent", "dedent",
    ]

    /// True if the input has unambiguous spoken-code signals: explicit
    /// punctuation/bracket words, or a run of single letters indicating
    /// letter-by-letter identifier spelling. Used by DeterministicCleanup
    /// to decide whether to run the spoken-symbol substitution pass.
    public static func looksLikeCodeDictation(_ raw: String) -> Bool {
        let lowered = raw.lowercased()
        let words = lowered.split(whereSeparator: { $0.isWhitespace }).map { String($0) }
        // Count single letters that aren't standalone English words ("I", "a").
        // Without this exclusion any sentence with 3+ "I"s would falsely match.
        let englishSingles: Set<String> = ["i", "a"]
        let codeyLetters = words.filter {
            $0.count == 1 && $0.first?.isLetter == true && !englishSingles.contains($0)
        }.count
        // Need a tight cluster — at least 3 non-English single letters AND
        // they should be ≥ 30% of total tokens (identifier spellings are dense).
        if codeyLetters >= 3 && Double(codeyLetters) / Double(words.count) >= 0.3 {
            return true
        }
        let tokens = lowered.split(whereSeparator: { !$0.isLetter })
        for token in tokens {
            if strongCodeKeywords.contains(String(token)) { return true }
        }
        return false
    }
}
