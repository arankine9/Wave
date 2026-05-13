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
/// Wave claims the Fn key for push-to-talk dictation, so we force this
/// to `.doNothing` on every launch. Intercepting Fn events via
/// `CGEventTap` alone isn't enough — macOS dispatches the emoji and
/// dictation overlays from HIToolbox's internal HID listener, separate
/// from the public event tap stream. Setting the preference is what
/// silences that listener.
///
/// HIToolbox caches the value in-memory. Writing the plist alone (via
/// `CFPreferencesSetAppValue` or `defaults write`) is **not** picked
/// up live — we also have to post the `com.apple.KeyboardUIModeDidChange`
/// distributed notification (the same signal System Settings posts via
/// the HIServices XPC service when the user changes the dropdown). See
/// `setFnUsageType` for the full recipe.
///
/// # How we know this works
///
/// Discovered empirically: traced `log stream` while flipping "Press 🌐
/// key to" in System Settings, saw every Apple process re-read
/// `AppleFnUsageType` within milliseconds (WindowServer, ControlCenter,
/// TextInputMenuAgent, CharacterPalette, …). `defaults write` from a
/// shell did NOT produce that cascade — so the prefpane was doing
/// something extra. Disassembling `com.apple.hiservices-xpcservice`
/// surfaced a fixed list of distributed-notification names the XPC
/// service is allowed to post; bisecting them against the prefpane's
/// behavior landed on `com.apple.KeyboardUIModeDidChange` as the one
/// HIToolbox actually listens for. Verified end-to-end: with the pref
/// at 0 and this notification posted, HIToolbox stops dispatching the
/// emoji/dictation overlay live, with no logout required.
///
/// # DO NOT
///
/// - Re-add a logout/restart prompt. The recipe below works live.
/// - Re-add the "make user toggle the dropdown in System Settings"
///   onboarding step. Wave handles it silently on every launch.
/// - Drop the `CFNotificationCenterPostNotification` call thinking
///   `CFPreferencesSetAppValue` is enough. It isn't — HIToolbox will
///   read stale state from its in-memory cache until the next login.
/// - Switch the notification name. We tested every candidate the
///   HIServices XPC service knows about; only this one moves
///   HIToolbox's cache. Others (e.g. `AppleSelectedInputSourcesChangedNotification`)
///   look related but don't trigger the refresh.
/// - Try to seize the keyboard via `IOHIDManager` with
///   `kIOHIDOptionsTypeSeizeDevice` to "bypass HIToolbox". That path
///   needs root or a DriverKit extension — overkill, and Wispr Flow
///   doesn't do it either (we checked).
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

    /// Writes the given value to `com.apple.HIToolbox` **and** kicks
    /// HIToolbox to reload its in-memory cache immediately — no
    /// logout required.
    ///
    /// The reload is triggered by posting the distributed notification
    /// `com.apple.KeyboardUIModeDidChange`. This is the same signal
    /// System Settings' Keyboard pane posts (via the HIServices XPC
    /// service) when the user changes "Press 🌐 key to" — discovered
    /// by tracing `log stream` while flipping the dropdown manually
    /// and then bisecting the candidate notification names defined in
    /// `com.apple.hiservices-xpcservice`. Once posted, every Apple
    /// process subscribed to HIToolbox prefs re-reads the value
    /// within milliseconds (we saw WindowServer, ControlCenter,
    /// TextInputMenuAgent, CharacterPalette, etc. all refresh).
    ///
    /// Writing the plist alone (via `CFPreferencesSetAppValue` or
    /// `defaults write`) is **not** enough — HIToolbox caches at
    /// login and ignores the on-disk change without this kick.
    @discardableResult
    public static func setFnUsageType(_ type: UsageType) -> Bool {
        let key = "AppleFnUsageType" as CFString
        let domain = "com.apple.HIToolbox" as CFString
        CFPreferencesSetAppValue(key, NSNumber(value: type.rawValue), domain)
        let ok = CFPreferencesAppSynchronize(domain)
        let name = CFNotificationName("com.apple.KeyboardUIModeDidChange" as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDistributedCenter(),
            name,
            nil,
            nil,
            true
        )
        return ok
    }

    /// Force-apply `.doNothing` on launch. Idempotent — returns the
    /// value that was in effect *before* we wrote (so callers can
    /// log whether the OS state needed correcting). Posts the
    /// reload notification unconditionally so even a no-op write
    /// still nudges HIToolbox in case its cache is somehow stale.
    @discardableResult
    public static func enforceDoNothing() -> UsageType? {
        let before = currentFnUsageType()
        _ = setFnUsageType(.doNothing)
        return before
    }

}
#endif
