#if canImport(AppKit)
import CoreFoundation
import Foundation

/// Reads and writes the `com.apple.HIToolbox AppleFnUsageType` preference
/// that controls what macOS does when you press the Fn (Globe) key:
///
///   0 — Do Nothing
///   1 — Change Input Source
///   2 — Show Emoji & Symbols
///   3 — Start Dictation
///
/// Wave claims the Fn key for push-to-talk dictation, so we set this to
/// `.doNothing` on launch. Intercepting Fn events via `CGEventTap` alone
/// isn't sufficient — macOS dispatches the emoji/dictation overlay from
/// HIToolbox observing HID directly, below the public event stream, so a
/// session-level tap never gets the chance to suppress it. Flipping the
/// preference is the only reliable route.
///
/// Caveat: macOS caches this preference at login. A user-visible change
/// of behavior requires a logout/login (or full restart) after the value
/// is first written. Subsequent launches are no-ops once the value sticks.
public enum FnSystemPreference {
    public enum UsageType: Int {
        case doNothing = 0
        case changeInputSource = 1
        case showEmoji = 2
        case startDictation = 3
    }

    /// Returns the current value, or nil if unset / malformed.
    public static func currentFnUsageType() -> UsageType? {
        let key = "AppleFnUsageType" as CFString
        let domain = "com.apple.HIToolbox" as CFString
        guard let raw = CFPreferencesCopyAppValue(key, domain) as? Int else {
            return nil
        }
        return UsageType(rawValue: raw)
    }

    /// Writes the given value to `com.apple.HIToolbox`. Returns whether
    /// the synchronous flush to cfprefsd succeeded.
    @discardableResult
    public static func setFnUsageType(_ type: UsageType) -> Bool {
        let key = "AppleFnUsageType" as CFString
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesSetAppValue(key, NSNumber(value: type.rawValue), domain)
        return CFPreferencesAppSynchronize(domain)
    }

    /// Mtime of the user's `com.apple.HIToolbox.plist`. We can't directly
    /// observe HIToolbox's in-memory cache, but the plist gets rewritten
    /// whenever System Settings (or `defaults write`) touches the domain.
    /// During onboarding we capture a baseline mtime, then watch for a
    /// later bump — that's the signal that the user actually did the
    /// toggle in System Settings (which is what kicks HIToolbox to
    /// re-read and apply the value).
    public static func hiToolboxPlistModificationDate() -> Date? {
        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Preferences/com.apple.HIToolbox.plist")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    /// Deep link to System Settings → Keyboard, where the user changes
    /// "Press 🌐 key to:" to "Do Nothing".
    public static let keyboardSettingsURL: URL = {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") else {
            preconditionFailure("invalid keyboard settings URL")
        }
        return url
    }()
}
#endif
