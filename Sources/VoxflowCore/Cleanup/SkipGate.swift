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
        "else",
        "return",
        "import",
        "from",
        "class",
        "struct",
        "enum",
        "async",
        "await",
        "self",
    ]

    /// Allowed characters when nothing in the text suggests code: letters, digits,
    /// spaces, common prose punctuation. Long inputs always go through cleanup
    /// because they're more likely to need fixups.
    private static let plainPattern: NSRegularExpression = {
        // letters, digits, spaces, comma, period, apostrophe, hyphen, question, exclamation
        return try! NSRegularExpression(pattern: "^[A-Za-z0-9 ,.'\\-?!]{1,80}$", options: [])
    }()

    public static func shouldSkipCleanup(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }

        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard plainPattern.firstMatch(in: trimmed, options: [], range: range) != nil else {
            return false
        }

        let lowered = trimmed.lowercased()
        let tokens = lowered.split(whereSeparator: { !$0.isLetter })
        for token in tokens {
            if codeKeywords.contains(String(token)) { return false }
        }
        return true
    }
}
