import Foundation

/// Remembers the most recent dictation so it can be re-pasted on demand (the
/// Ctrl+Cmd+V repaste hotkey, wired in `AppDelegate`).
///
/// Conforms to `DictationLogger` so it updates automatically at the end of
/// every dictation cycle, riding the same hook that feeds the history log —
/// see `CompositeDictationLogger`. The stored value is the cleaned `finalText`
/// that was actually pasted, which is what a user re-pasting "my last
/// dictation" expects to get back.
public final class LastDictationStore: DictationLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var _text: String?

    /// Seed with a prior dictation (e.g. the last line of the history log on
    /// launch) so repaste works across app restarts, not just within a
    /// session. Pass nil for a fresh store.
    public init(text: String? = nil) {
        _text = text
    }

    /// The most recent non-empty dictation, or nil if nothing has been
    /// dictated yet.
    public var text: String? {
        lock.withLock { _text }
    }

    public func record(_ trace: DictationTrace) {
        // Empty utterances (silence, a discarded tap) are still logged to
        // history but must not wipe the repaste buffer — keep the last text
        // that actually produced a paste.
        guard !trace.finalText.isEmpty else { return }
        lock.withLock { _text = trace.finalText }
    }
}
