#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation

public enum PasterError: Error {
    case missingAccessibility
    case eventCreateFailed
}

public protocol Paster: AnyObject, Sendable {
    func paste(_ text: String) throws
}

/// Default paster: writes to NSPasteboard then synthesizes Cmd+V.
///
/// Preserves whatever the user had on the clipboard before paste. The
/// original items are snapshotted, our text is written and Cmd+V posted,
/// then a short delay later (after the frontmost app has had a chance to
/// read the pasteboard) we restore the original contents — unless the
/// pasteboard has been written to in the meantime, in which case we leave
/// it alone so we don't clobber a fresh user copy.
///
/// The restore is a race against the paste target: Cmd+V is delivered as a
/// synthetic key event that the frontmost app consumes *asynchronously*,
/// whenever it gets around to processing the keystroke. If we restore the
/// snapshot before the app has read the pasteboard, the app pastes the OLD
/// contents (e.g. a file name copied in Finder) instead of the dictation.
/// `restoreDelay` is therefore sized generously — the only cost of a longer
/// delay is that our text sits on the clipboard a little longer, whereas a
/// too-short delay produces a visible wrong-paste on slow/busy apps.
public final class ClipboardPaster: Paster, @unchecked Sendable {
    /// Window we leave the dictated text on the clipboard before restoring,
    /// so even a sluggish frontmost app finishes consuming the Cmd+V first.
    /// Was 0.15s, which lost the race on slower machines / heavy apps.
    public static let defaultRestoreDelay: TimeInterval = 0.6

    private let pasteboard: NSPasteboard
    private let restoreDelay: TimeInterval
    private let postPasteHotkey: @Sendable () throws -> Void
    private let scheduleRestore: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void

    public convenience init(
        pasteboard: NSPasteboard = .general,
        restoreDelay: TimeInterval = ClipboardPaster.defaultRestoreDelay
    ) {
        self.init(
            pasteboard: pasteboard,
            restoreDelay: restoreDelay,
            postPasteHotkey: ClipboardPaster.postCommandV,
            scheduleRestore: { delay, block in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: block)
            }
        )
    }

    /// Designated init exposed for tests so they can inject a no-op hotkey
    /// poster (avoids the Accessibility requirement) and a synchronous
    /// scheduler.
    init(
        pasteboard: NSPasteboard,
        restoreDelay: TimeInterval,
        postPasteHotkey: @escaping @Sendable () throws -> Void,
        scheduleRestore: @escaping @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        self.postPasteHotkey = postPasteHotkey
        self.scheduleRestore = scheduleRestore
    }

    public func paste(_ text: String) throws {
        let snapshot = Self.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let expectedChangeCount = pasteboard.changeCount
        do {
            try postPasteHotkey()
        } catch {
            // Cmd+V never went out, so nothing will consume the pasteboard.
            // Restore immediately rather than waiting out the delay.
            Self.restore(RestorePayload(
                snapshot: snapshot,
                pasteboard: pasteboard,
                expectedChangeCount: expectedChangeCount
            ))
            throw error
        }
        guard !snapshot.isEmpty else { return }
        let payload = RestorePayload(
            snapshot: snapshot,
            pasteboard: pasteboard,
            expectedChangeCount: expectedChangeCount
        )
        scheduleRestore(restoreDelay) {
            Self.restore(payload)
        }
    }

    /// Bundles the bits the deferred restore needs to carry across a
    /// `@Sendable` boundary. NSPasteboard / NSPasteboardItem aren't formally
    /// Sendable, but the pasteboard is thread-safe and the snapshot items
    /// are only read on the restore side, so unchecked is fine here.
    private struct RestorePayload: @unchecked Sendable {
        let snapshot: [NSPasteboardItem]
        let pasteboard: NSPasteboard
        let expectedChangeCount: Int
    }

    /// Deep-copy every item on the pasteboard so the original contents can
    /// be re-written later. `NSPasteboardItem` is single-use once written,
    /// so we materialize each type's data into a fresh item.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private static func restore(_ payload: RestorePayload) {
        guard !payload.snapshot.isEmpty else { return }
        // The change count being untouched since our write is the single
        // guard that makes restore safe: it means our dictated text is still
        // exactly what's on the pasteboard AND nobody else (the user, another
        // tool, a slow paste target) has written since. If anything wrote
        // after us — a fresh user copy — that's intentional state, so leave
        // it alone rather than clobbering it with the stale snapshot.
        guard payload.pasteboard.changeCount == payload.expectedChangeCount else { return }
        payload.pasteboard.clearContents()
        payload.pasteboard.writeObjects(payload.snapshot)
    }

    static func postCommandV() throws {
        guard AXIsProcessTrusted() else { throw PasterError.missingAccessibility }
        let source = CGEventSource(stateID: .combinedSessionState)
        // 'v' on macOS US keyboard is virtual keycode 9.
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { throw PasterError.eventCreateFailed }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

/// Alternate paster: types each character via synthetic key events. Slower
/// but matches the source app's text-entry behavior more faithfully (e.g. in
/// rich-text fields that strip clipboard formatting).
public final class TypingPaster: Paster, @unchecked Sendable {
    public init() {}

    public func paste(_ text: String) throws {
        guard AXIsProcessTrusted() else { throw PasterError.missingAccessibility }
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw PasterError.eventCreateFailed }
            var utf16: [UniChar] = Array(String(scalar).utf16)
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}

public enum PasterFactory {
    public static func make(mode: PasteMode) -> Paster {
        switch mode {
        case .paste: return ClipboardPaster()
        case .type:  return TypingPaster()
        }
    }
}
#endif
