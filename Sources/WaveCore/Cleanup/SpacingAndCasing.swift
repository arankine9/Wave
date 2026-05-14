import Foundation

/// Spacing + sentence-casing normalization. Direct port of talonhub/community's
/// `core/text/text_and_dictation.py` — two declarative regexes for spacing and
/// a small state machine for capitalization. The `noCapAfter` tail-regex is
/// what distinguishes "I." (sentence end) from "i.e." (no cap follows).
public enum SpacingAndCasing {

    // Characters that never need a space *before* them (closing punctuation,
    // close brackets, sentence terminators, possessive 's, etc.). Curly
    // quotes are embedded literally so ICU doesn't choke on \u{} escapes.
    private static let noSpaceBefore: NSRegularExpression = {
        let pattern = "^(?:[\\s\\-_.,!?/%)\\]}\u{2019}\u{201D}]|[$£€¥₩₽₹](?!\\w)|[;:](?!-\\)|-\\()|['\"](?:$|[\\s)\\]}\\-'\".,!?;:/])|'s(?!\\w))"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    // Characters that never need a space *after* them (opening brackets,
    // word-prefix currency, opening quotes following whitespace/brackets).
    private static let noSpaceAfter: NSRegularExpression = {
        let pattern = "(?:[\\s\\-_/#@(\\[{\u{2018}\u{201C}]|(?<!\\w)[$£€¥₩₽₹]|(?:^|[\\s(\\[{\\-'\"])['\"])$"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    // Abbreviations whose terminal "." does NOT signal sentence end.
    // Talon ships `e.g.` and `i.e.`; we add common honorifics + a few others.
    private static let noCapAfter: NSRegularExpression = {
        let pattern = #"""
        (?:
            e\.g\.
          | i\.e\.
          | etc\.
          | vs\.
          | (?:^|[\s\(\[\{])(?:Mr|Mrs|Ms|Dr|Sr|Jr|St)\.
        )$
        """#
        return try! NSRegularExpression(pattern: pattern, options: [.allowCommentsAndWhitespace])
    }()

    /// Walk the text token-by-token and drop spaces around glued punctuation.
    /// Input is a string with normal-ish spacing; output is the same string
    /// with no-space-before / no-space-after rules enforced.
    public static func normalizeSpacing(_ raw: String) -> String {
        // Split on runs of whitespace, preserving non-empty tokens. Rejoin
        // pairwise using the Talon rule: need_space = !(omit_after(a) || omit_before(b)).
        let parts = raw.split(omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let first = parts.first else { return "" }
        var out = first
        for next in parts.dropFirst() {
            let needSpace = !(matches(noSpaceAfter, out) || matches(noSpaceBefore, next))
            out += needSpace ? " " + next : next
        }
        return out
    }

    /// Capitalize sentence starts. State is internal — we always begin in
    /// "sentence start" because we treat the input as a complete utterance.
    public static func autoCapitalize(_ text: String) -> String {
        var output = ""
        var charge = true                  // next alnum char gets capitalized
        var newline = false                // last emitted char was '\n'
        var sentenceEnd = false            // last emitted char was '.!?'
        var emittedSoFar = ""              // accumulator used for noCapAfter lookups

        for ch in text {
            // Whitespace right after sentence-end is a "charge carrier".
            // Any newline triggers charge — in dictation, a "new line"
            // command is always a sentence boundary (deviates from Talon,
            // which only capitalizes after a blank line).
            if (sentenceEnd && (ch == " " || ch == "\n" || ch == "\t")) || ch == "\n" || (newline && ch == "\n") {
                charge = true
            } else if charge && (ch.isLetter || ch.isNumber || ch == "," || ch == ":") {
                charge = false
                let upper = String(ch).uppercased()
                output += upper
                emittedSoFar += upper
                newline = false
                // Letters/digits cannot themselves end a sentence.
                sentenceEnd = false
                continue
            }

            output.append(ch)
            emittedSoFar.append(ch)
            newline = ch == "\n"
            if ch == "." || ch == "!" || ch == "?" {
                sentenceEnd = !matches(noCapAfter, emittedSoFar)
            } else if !ch.isWhitespace {
                sentenceEnd = false
            }
        }
        return output
    }

    /// Convenience: spacing then casing. Order matters — casing relies on
    /// terminal punctuation being adjacent to the prior word.
    public static func transform(_ raw: String) -> String {
        return autoCapitalize(normalizeSpacing(raw))
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return re.firstMatch(in: s, options: [], range: range) != nil
    }
}
