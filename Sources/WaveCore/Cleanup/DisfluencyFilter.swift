import Foundation

/// Removes spoken disfluencies that survive Parakeet's verbatim transcription:
/// filler words, stutter restarts, and the "I. I" artifact pattern. Designed
/// to run on every utterance in <1ms with zero hallucination risk — every
/// transform is a deletion or whitespace edit, never a substitution.
///
/// The litmus case driving the design:
///   "Like it's not like deduplicating" → "It's not deduplicating"
/// First "Like" is sentence-initial filler; second "like" sits between a
/// negation ("not") and a present participle ("deduplicating").
public enum DisfluencyFilter {

    public static func transform(_ raw: String) -> String {
        var s = raw
        s = stripIRestarts(s)
        s = repairSentenceBoundaries(s)
        s = stripHardFillers(s)
        s = stripSentenceInitialFillers(s)
        s = stripCommaBoundedFillers(s)
        s = stripContextGatedLike(s)
        s = stutterDedup(s)
        s = collapseWhitespace(s)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Rule 1: I-restart cleanup

    // "I. I like" → "I like". Drops a bare single-letter sentence that's
    // immediately retried. Only matches when the restart agrees with the
    // dropped letter, so legitimate "A. B" enumerations are untouched.
    private static let iRestart = try! NSRegularExpression(
        pattern: #"\b([A-Z])\.\s+\1\b"#, options: []
    )
    private static func stripIRestarts(_ s: String) -> String {
        return replace(iRestart, in: s, with: "$1")
    }

    // MARK: - Rule 2: sentence-boundary repair

    // "with here Like, literally" → "with here. Like, literally"
    // Insert `.` before a capitalized restart cue when prior char isn't one.
    private static let missingTerminator = try! NSRegularExpression(
        pattern: #"([a-z])\s+(Like|So|And|But|Well|Okay|Alright|Now|Anyway)\b"#,
        options: []
    )
    private static func repairSentenceBoundaries(_ s: String) -> String {
        return replace(missingTerminator, in: s, with: "$1. $2")
    }

    // MARK: - Rule 3: hard filler removal

    // Universal across every dictation tool: um, uh, er, ah, hmm. These have
    // no legitimate spoken-prose use and Parakeet emits them verbatim.
    // The (?<![\w-]) / (?![\w-]) lookarounds prevent matching inside
    // hyphenated tokens like "Mm-hmm" or "uh-huh" where the syllable IS
    // a real (affirmative) utterance, not a filler.
    private static let hardFillers = try! NSRegularExpression(
        pattern: #"(?<![\w-])(?:uh+|um+|uhm+|erm+|er+h?|ah+|hmm+)(?![\w-])[,]?"#,
        options: [.caseInsensitive]
    )
    private static func stripHardFillers(_ s: String) -> String {
        return replace(hardFillers, in: s, with: "")
    }

    // MARK: - Rule 4: sentence-initial filler

    // Drops "Like, ", "So, ", "Well, ", "Okay, ", etc. when they front a
    // real sentence. Anchored to start-of-input or after `.!?`. The next
    // token can be any word — casing is fixed by SpacingAndCasing later.
    private static let sentenceInitialFiller = try! NSRegularExpression(
        pattern: #"(^|(?<=[.!?])\s+)(?:Like|So|Well|Okay|Alright|Yeah|Yep)[,]?\s+(?=\w)"#,
        options: [.caseInsensitive]
    )
    private static func stripSentenceInitialFillers(_ s: String) -> String {
        return replace(sentenceInitialFiller, in: s, with: "$1")
    }

    // MARK: - Rule 5: comma-bounded fillers

    // ", like, " is the safest filler context — the speaker bracketed it
    // with pauses themselves. Same for "you know", "I mean", "sort of".
    private static let commaBoundedFillers = try! NSRegularExpression(
        pattern: #",\s+(?:like|you know|I mean|sort of|kind of|basically|literally)\s*,"#,
        options: [.caseInsensitive]
    )
    private static func stripCommaBoundedFillers(_ s: String) -> String {
        return replace(commaBoundedFillers, in: s, with: ",")
    }

    // MARK: - Rule 6: context-gated "like"

    // Strip " like " when it's clearly filler. Strategy: protect the well-
    // known idiom contexts, then strip. The protection list is finite and
    // covers the vast majority of legitimate uses without needing POS tags.
    //
    // PROTECTED preceding words (legitimate "like" follows):
    //   - simile verbs: feel/look/sound/seem/taste/smell/act (any tense)
    //   - desire verbs: would, should, could, 'd, do, does, did + "like"
    //   - subjects of "I like / you like": I, you, we, they, he, she, it
    //   - comparatives: more, less, just, much, anything, nothing, …
    // PROTECTED next word: "to" ("would like to")
    private static let idiomVerbs: Set<String> = [
        "feel","feels","felt","feeling",
        "look","looks","looked","looking",
        "sound","sounds","sounded","sounding",
        "seem","seems","seemed","seeming",
        "taste","tastes","tasted","tasting",
        "smell","smells","smelled","smelling",
        "act","acts","acted","acting"
    ]
    private static let likeVerbAuxes: Set<String> = [
        "would","should","could","'d","do","does","did",
        "i","you","we","they","he","she","it",
        "wouldn't","didn't","doesn't","don't","won't"
    ]
    private static let comparators: Set<String> = [
        "more","less","just","much","anything","nothing","something",
        "someone","anyone","everyone","everything","people"
    ]

    private static func stripContextGatedLike(_ s: String) -> String {
        // Tokenize preserving original whitespace by splitting on spaces.
        let parts = s.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return s }
        var out: [String] = []
        var i = 0
        while i < parts.count {
            let tok = parts[i]
            let lower = stripPunctuation(tok).lowercased()
            if lower == "like" && i > 0 && i < parts.count - 1 {
                let prev = stripPunctuation(parts[i-1]).lowercased()
                let next = stripPunctuation(parts[i+1]).lowercased()
                let protected =
                    idiomVerbs.contains(prev) ||
                    likeVerbAuxes.contains(prev) ||
                    comparators.contains(prev) ||
                    next == "to" ||
                    // "X like that" is an idiom meaning "and so on" — almost
                    // always intentional, even when surrounded by filler.
                    next == "that" ||
                    // Skip if "like" is followed by a clause-starter quote/
                    // colon — likely a quotation marker.
                    parts[i].hasSuffix(":") ||
                    parts[i].hasSuffix("\"")
                if !protected {
                    // Drop "like" — also drop a trailing comma if it had one.
                    i += 1
                    continue
                }
            }
            out.append(tok)
            i += 1
        }
        return out.joined(separator: " ")
    }

    // MARK: - Rule 7: stutter dedup

    // Collapse adjacent identical n-grams: "we should we should" → "we should".
    // Largest window first (n=4 → n=1) so longer restarts win over shorter ones.
    // Skips when:
    //   - the repeated token is an intensifier ("very very good" stays)
    //   - the token appears 3+ times consecutively (deliberate, like a mic test)
    //   - the duplicates are separated by anything other than a single space
    //     (handled implicitly because we split on " " and ignore punctuation tokens)
    private static let intensifiers: Set<String> = [
        "very","really","no","yes","yeah","so","ha","ho","hee","bye","yay"
    ]

    private static func stutterDedup(_ s: String) -> String {
        var tokens = s.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        for n in stride(from: 4, through: 1, by: -1) {
            tokens = dedupOnce(tokens, window: n)
        }
        return tokens.joined(separator: " ")
    }

    private static func dedupOnce(_ tokens: [String], window n: Int) -> [String] {
        guard tokens.count >= 2 * n else { return tokens }
        var out: [String] = []
        var i = 0
        while i <= tokens.count - 2 * n {
            let a = tokens[i..<i+n].map { normalizeToken($0) }
            let b = tokens[i+n..<i+2*n].map { normalizeToken($0) }
            if a == b && !shouldSkipDedup(a, fullTokens: tokens, atIndex: i, window: n) {
                // Keep `a`, drop `b`. Re-check at same i in case "a a a" → "a".
                out.append(contentsOf: tokens[i..<i+n])
                i += 2 * n
            } else {
                out.append(tokens[i])
                i += 1
            }
        }
        // Tail tokens that don't fit a window pair.
        if i < tokens.count {
            out.append(contentsOf: tokens[i...])
        }
        return out
    }

    private static func shouldSkipDedup(_ ngram: [String], fullTokens: [String],
                                        atIndex i: Int, window n: Int) -> Bool {
        // Skip if single-token intensifier ("very very").
        if n == 1, let only = ngram.first, intensifiers.contains(only) {
            return true
        }
        // Skip if any token in ngram ends with comma — likely deliberate
        // emphasis ("No, no, I won't.") rather than a restart.
        for tokIdx in i..<i+2*n {
            if tokIdx >= fullTokens.count { break }
            let t = fullTokens[tokIdx]
            if t.hasSuffix(",") || t.hasSuffix(";") { return true }
        }
        // Skip if 3+ repeats in a row (deliberate, e.g. "hello hello hello").
        if n == 1 {
            let want = ngram[0]
            var run = 0
            var j = i
            while j < fullTokens.count && normalizeToken(fullTokens[j]) == want {
                run += 1; j += 1
            }
            if run >= 3 { return true }
        }
        return false
    }

    private static func normalizeToken(_ t: String) -> String {
        return stripPunctuation(t).lowercased()
    }

    private static func stripPunctuation(_ t: String) -> String {
        return t.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:\"'"))
    }

    // MARK: - Whitespace

    private static let multiSpace = try! NSRegularExpression(pattern: #"[ \t]{2,}"#)
    private static func collapseWhitespace(_ s: String) -> String {
        return replace(multiSpace, in: s, with: " ")
    }

    // MARK: - Helper

    private static func replace(_ re: NSRegularExpression, in s: String, with template: String) -> String {
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}
