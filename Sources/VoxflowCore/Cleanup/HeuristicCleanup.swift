import Foundation

/// Regex-based fallback cleanup. Used when no LLM is reachable so the app
/// still produces sensible code-shaped output. Not a replacement for the
/// LLM path; identifier reassembly and language-specific syntax are still
/// best handled by Ollama.
public enum HeuristicCleanup {
    private struct Replacement {
        let pattern: String
        let template: String
    }

    /// Spoken-symbol replacements. Order matters: compound forms like
    /// "double equals" must run before single "equals", and close-paren
    /// before open-paren so the standalone "paren" inside "close paren"
    /// isn't consumed by the open rule.
    private static let symbols: [Replacement] = [
        .init(pattern: "\\bdouble\\s+equals\\b", template: "=="),
        .init(pattern: "\\bnot\\s+equals\\b", template: "!="),
        .init(pattern: "\\bfat\\s+arrow\\b", template: "=>"),
        .init(pattern: "\\bnew\\s+line\\b", template: "\n"),
        .init(pattern: "\\b(?:close|right|closed)\\s+(?:parenthesis|paren|parens)\\b", template: ")"),
        .init(pattern: "\\b(?:open|left)\\s+(?:parenthesis|paren|parens)\\b", template: "("),
        .init(pattern: "\\b(?:close|right|closed)\\s+(?:bracket|brackets)\\b", template: "]"),
        .init(pattern: "\\b(?:open|left)\\s+(?:bracket|brackets)\\b", template: "["),
        .init(pattern: "\\b(?:close|right|closed)\\s+(?:brace|braces|curly)\\b", template: "}"),
        .init(pattern: "\\b(?:open|left)\\s+(?:brace|braces|curly)\\b", template: "{"),
        .init(pattern: "\\b(?:equals|equal\\s+sign|equal)\\b", template: "="),
        .init(pattern: "\\bunderscore\\b", template: "_"),
        .init(pattern: "\\bdot\\b", template: "."),
        .init(pattern: "\\bcomma\\b", template: ","),
        .init(pattern: "\\bsemicolon\\b", template: ";"),
        .init(pattern: "\\bcolon\\b", template: ":"),
        .init(pattern: "\\bdollar(?:\\s+sign)?\\b", template: "$"),
        .init(pattern: "\\bpercent(?:\\s+sign)?\\b", template: "%"),
        .init(pattern: "\\bampersand\\b", template: "&"),
        .init(pattern: "\\bcaret\\b", template: "^"),
        .init(pattern: "\\bpipe\\b", template: "|"),
        .init(pattern: "\\btilde\\b", template: "~"),
        .init(pattern: "\\basterisk\\b", template: "*"),
        .init(pattern: "\\bslash\\b", template: "/"),
        .init(pattern: "\\bbackslash\\b", template: "\\\\"),
        .init(pattern: "\\bplus\\b", template: "+"),
        .init(pattern: "\\bminus\\b", template: "-"),
        .init(pattern: "\\barrow\\b", template: "->"),
        .init(pattern: "\\bnewline\\b", template: "\n"),
    ]

    /// Spoken digit-words → digits. Applied as whole tokens so "ten" doesn't
    /// pollute "often".
    private static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10",
    ]

    public static func transform(_ raw: String) -> String {
        var s = raw

        for replacement in symbols {
            s = applyRegex(replacement, to: s)
        }

        s = replaceNumberWords(s)
        s = collapseSingleLetterRuns(s)
        s = tightenSymbolSpacing(s)
        s = collapseWhitespace(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func applyRegex(_ r: Replacement, to s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: r.pattern, options: [.caseInsensitive]) else {
            return s
        }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: r.template)
    }

    private static func replaceNumberWords(_ s: String) -> String {
        s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " })
            .map { word -> String in
                let lower = word.lowercased()
                if let digit = numbers[lower] { return digit }
                return String(word)
            }
            .joined(separator: " ")
    }

    /// "u s e r underscore i d" -> "user _ id". Together with the underscore
    /// rule above, the user gets "user_id". Joins runs of 2+ single-letter
    /// alphabetic tokens.
    private static func collapseSingleLetterRuns(_ s: String) -> String {
        var out: [String] = []
        var run: [String] = []
        for word in s.split(omittingEmptySubsequences: false, whereSeparator: { $0 == " " }).map(String.init) {
            if word.count == 1 && word.first?.isLetter == true {
                run.append(word)
            } else {
                if run.count >= 2 {
                    out.append(run.joined())
                } else if let single = run.first {
                    out.append(single)
                }
                run.removeAll()
                out.append(word)
            }
        }
        if run.count >= 2 {
            out.append(run.joined())
        } else if let single = run.first {
            out.append(single)
        }
        return out.joined(separator: " ")
    }

    private static func tightenSymbolSpacing(_ s: String) -> String {
        var out = s
        // Drop spaces around tightly-bound symbols that the model would never write padded.
        let tighten: [(String, String)] = [
            ("\\s*\\.\\s*", "."),
            ("\\s*_\\s*", "_"),
            ("\\s*\\(\\s*", "("),
            ("\\s*\\)\\s*", ")"),
            ("\\s*\\[\\s*", "["),
            ("\\s*\\]\\s*", "]"),
            ("\\s*,\\s*", ", "),
            ("\\s+;", ";"),
            ("\\s+\\?", "?"),
            ("\\s+!", "!"),
        ]
        for (pat, rep) in tighten {
            if let re = try? NSRegularExpression(pattern: pat) {
                let range = NSRange(out.startIndex..., in: out)
                out = re.stringByReplacingMatches(in: out, range: range, withTemplate: rep)
            }
        }
        return out
    }

    private static func collapseWhitespace(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "[ \\t]{2,}") else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: " ")
    }
}
