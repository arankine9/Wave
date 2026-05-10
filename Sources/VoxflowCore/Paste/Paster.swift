#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation

public enum PasterError: Error {
    case missingAccessibility
    case eventCreateFailed
}

public protocol Paster: AnyObject {
    func paste(_ text: String) throws
}

/// Default paster: writes to NSPasteboard then synthesizes Cmd+V.
public final class ClipboardPaster: Paster {
    private let pasteboard: NSPasteboard
    public init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    public func paste(_ text: String) throws {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        try Self.postCommandV()
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
public final class TypingPaster: Paster {
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
