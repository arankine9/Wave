#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum FnKeyMonitorError: Error {
    case missingPermission
    case tapCreationFailed
}

extension Notification.Name {
    /// Posted on the main queue whenever the physical Fn (Globe) key
    /// transitions. `userInfo["pressed"]` is a `Bool`. Subscribers in the
    /// app (e.g. onboarding tutorial) use this instead of installing their
    /// own NSEvent monitor — the production tap consumes the event before
    /// it would reach a passive monitor.
    public static let waveFnKeyChanged = Notification.Name("wave.fnkey.changed")
}

/// Listens for the macOS Fn (Globe) modifier flag via a `CGEventTap` and
/// CONSUMES the underlying `flagsChanged` events so macOS's built-in
/// "Press 🌐 key to…" feature (emoji picker / Start Dictation / change
/// input source) cannot fire while Wave owns this key.
///
/// IMPORTANT: this tap alone does NOT suppress the emoji/dictation
/// overlay on a system where `AppleFnUsageType` is its default value.
/// HIToolbox dispatches that overlay from its own internal HID
/// listener, separate from the public CGEvent stream. Pair this
/// monitor with `FnSystemPreference.enforceDoNothing()` on launch —
/// see that file for the full story.
///
/// Design notes:
///
///   1. Tap placement is `kCGHIDEventTap` (not `kCGSessionEventTap`).
///      Events flow HID-tap → session-tap → apps, so being at the HID
///      level is strictly earlier than any peer app at the session
///      level. Combined with `.headInsertEventTap` this puts us at
///      the very front of the chain among HID taps.
///   2. We listen for `keyDown`/`keyUp` in addition to `flagsChanged`,
///      and pass them through untouched. We never *need* the events
///      directly, but keeping the tap's event mask broad keeps it
///      busy, which makes macOS less aggressive about
///      `.tapDisabledByTimeout`.
///   3. The watchdog timer re-enables the tap every 2 seconds if
///      macOS quiesced it. Both `.tapDisabledByTimeout` (callback
///      overrun) and `.tapDisabledByUserInput` (kernel-level reset,
///      sleep/wake, sandbox transition) are handled. Without this
///      the most common failure mode is "Fn stopped working until I
///      relaunched the app".
///
/// Requires Accessibility permission. We do not need Input Monitoring
/// because we only react to modifier flags — Accessibility is
/// sufficient for `CGEventTapCreate` at either tap location.
public final class FnKeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFnDown = false
    private var watchdogTimer: DispatchSourceTimer?

    public var onPressed: (@Sendable () -> Void)?
    public var onReleased: (@Sendable () -> Void)?

    public init() {}

    public func start() throws {
        guard eventTap == nil else { return }
        guard FnKeyMonitor.hasAccessibilityPermission() else {
            throw FnKeyMonitorError.missingPermission
        }
        try installTap()
        startWatchdog()
    }

    public func stop() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
        teardownTap()
        lastFnDown = false
    }

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func installTap() throws {
        // flagsChanged is the only event the Fn key fires on its own,
        // but keyDown/keyUp let us see chords (Fn+letter), which we
        // pass through unchanged. otherMouse* mirrors Wispr Flow's
        // event mask — handy for future chord work, cheap to listen
        // for, and keeps the tap's "interesting" budget warm so the
        // OS is less likely to silence it for inactivity.
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // .cghidEventTap is the lowest user-space tap point. Events
        // arrive here before any session-level tap (which is where
        // peer apps install). Combined with .headInsertEventTap, we
        // sit at the very front of the chain.
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            throw FnKeyMonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.eventTap = tap
        self.runLoopSource = source
    }

    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
    }

    /// macOS silently disables a tap if anything goes wrong (callback
    /// overrun, kernel HID reset, sleep/wake, app sandbox transition).
    /// The watchdog re-enables a quiesced tap, and if the port itself
    /// has gone invalid it rebuilds from scratch. Without this, the
    /// most common user-visible failure mode is "Fn stopped working
    /// until I relaunched."
    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2.0, repeating: 2.0)
        timer.setEventHandler { [weak self] in
            self?.healTap()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func healTap() {
        guard let tap = eventTap else {
            try? installTap()
            return
        }
        if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if !CGEvent.tapIsEnabled(tap: tap) {
                // Port is dead — rebuild.
                teardownTap()
                try? installTap()
            }
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap whose callback overran its budget
        // OR when something noisy on the bus tripped its safety. Both
        // cases produce a synthetic event we MUST handle inline; the
        // watchdog is a backstop, not the primary path.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            // keyDown/keyUp/otherMouse events: pass through untouched.
            // We listen so the tap stays warm; we never want to swallow
            // a real keystroke.
            return Unmanaged.passUnretained(event)
        }

        let isFnDown = event.flags.contains(.maskSecondaryFn)
        guard isFnDown != lastFnDown else {
            // Some other modifier toggled while Fn was steady — let it through.
            return Unmanaged.passUnretained(event)
        }
        lastFnDown = isFnDown
        if isFnDown {
            onPressed?()
        } else {
            onReleased?()
        }
        NotificationCenter.default.post(
            name: .waveFnKeyChanged,
            object: nil,
            userInfo: ["pressed": isFnDown]
        )
        // Consume so macOS's "Press 🌐 key to…" handler never sees it.
        return nil
    }
}
#endif
