import Foundation

/// Decides whether a raw transcript can be pasted as-is, bypassing the cleanup
/// LLM. This is rule 1 in project.md "Token-efficiency rules": short, plain
/// content with no spoken-code signals doesn't need an LLM round-trip.
public enum SkipGate {
    /// Spoken signals that the user is dictating code structure. If any of these
    /// appear in the raw transcript, we always run cleanup.
    static let codeKeywords: Set<String> = [
        "paren", "parens", "parenthesis",
        "bracket", "brackets",
        "brace", "braces", "curly",
        "equals", "equal",
        "dot",
        "dollar",
        "percent",
        "semicolon",
        "colon",
        "arrow",
        "lambda",
        "underscore",
        "tilde",
        "ampersand",
        "pipe",
        "caret",
        "asterisk",
        "slash",
        "backslash",
        "plus",
        "minus",
        "hash",
        "hashtag",
        "quote",
        "tick",
        "backtick",
        "newline",
        "tab",
        "indent",
        "dedent",
        "function",
        "def",
        "var",
        "let",
        "const",
        "if",
        "range",
        "while",
        "switch",
        "break",
        "continue",
        "return",
        "yield",
        "import",
        "class",
        "struct",
        "enum",
        "interface",
        "trait",
        "async",
        "await",
        "throw",
        "throws",
        "catch",
        "finally",
        "null",
        "nil",
        "promise",
    ]

    /// Allowed characters when nothing in the text suggests code: letters, digits,
    /// spaces, common prose punctuation. Long inputs always go through cleanup
    /// because they're more likely to need fixups.
    private static let plainPattern: NSRegularExpression = {
        // letters, digits, spaces, comma, period, apostrophe, hyphen, question, exclamation
        return try! NSRegularExpression(pattern: "^[A-Za-z0-9 ,.'\\-?!]{1,80}$", options: [])
    }()

    /// Unambiguous spoken-code tokens. Subset of `codeKeywords` that avoids
    /// common English words ("if", "return", "class", "let", "function") which
    /// would falsely flag prose as code. Used only by `looksLikeCodeDictation`;
    /// SkipGate's prose/code split keeps the broader list because in that
    /// context length and character set act as additional guards.
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

    public static func shouldSkipCleanup(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard plainPattern.firstMatch(in: trimmed, options: [], range: range) != nil else {
            return false
        }

        let lowered = trimmed.lowercased()
        let words = lowered.split(whereSeparator: { $0.isWhitespace }).map { String($0) }

        // Spelling heuristic: when the user dictates an identifier letter by
        // letter ("u s e r underscore i d", "x m l h t t p request"), most
        // tokens become single letters. Force cleanup so the model can
        // reassemble them, otherwise the gate would discard the structure.
        let singleLetterCount = words.filter { $0.count == 1 && $0.first?.isLetter == true }.count
        if singleLetterCount >= 3 || (words.count > 0 && Double(singleLetterCount) / Double(words.count) >= 0.4) {
            return false
        }

        let tokens = lowered.split(whereSeparator: { !$0.isLetter })
        for token in tokens {
            if codeKeywords.contains(String(token)) { return false }
        }
        return true
    }
}
