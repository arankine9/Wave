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
/// Non-Fn modifier changes (Shift, Cmd, Option, Ctrl, Caps Lock) pass
/// through untouched. Requires Accessibility permission to install the
/// tap; we do not need Input Monitoring because we only react to modifier
/// flags, not keystroke content.
public final class FnKeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFnDown = false

    public var onPressed: (@Sendable () -> Void)?
    public var onReleased: (@Sendable () -> Void)?

    public init() {}

    public func start() throws {
        guard eventTap == nil else { return }
        guard FnKeyMonitor.hasAccessibilityPermission() else {
            throw FnKeyMonitorError.missingPermission
        }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
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

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        lastFnDown = false
    }

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap whose callback overran its budget;
        // re-enable so we don't go deaf after a brief main-thread stall.
        if type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
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
