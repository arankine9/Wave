import Foundation

/// Three-stage pure-Swift cleanup that runs on every utterance. Needs no
/// network and is fast enough to run inline on the dictation path. Order
/// matters:
///
///   1. DisfluencyFilter — drop fillers, dedup stutters, fix I-restarts.
///      Must run first so later passes don't re-introduce wrong-cased
///      starts or mis-spaced punctuation from now-deleted tokens.
///
///   2. HeuristicCleanup — only if the utterance looks like code dictation
///      (contains "paren", "dot", "equals", spelled-out identifiers, etc.).
///      Skipped for plain prose because mapping `\bcomma\b` → `,` would
///      mangle sentences like "the comma button".
///
///   3. SpacingAndCasing — Talon port. Normalize spaces around punctuation
///      and capitalize sentence starts.
public enum DeterministicCleanup {
    public static func transform(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        var s = DisfluencyFilter.transform(trimmed)
        if SkipGate.looksLikeCodeDictation(s) {
            // Code mode: HeuristicCleanup handles spacing around symbols and
            // we deliberately skip sentence-casing — "(self.id)" must not
            // become "(Self.id)".
            s = HeuristicCleanup.transform(s)
        } else {
            s = SpacingAndCasing.transform(s)
        }
        return s
    }
}
