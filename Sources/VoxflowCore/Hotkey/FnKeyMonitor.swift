#if canImport(AppKit)
import AppKit
import CoreGraphics
import Foundation

public enum FnKeyMonitorError: Error {
    case tapCreateFailed
    case missingPermission
}

/// Listens for the macOS Fn (Globe) modifier flag via a low-level CGEventTap.
/// Requires the user to grant Input Monitoring (and typically Accessibility)
/// in System Settings → Privacy & Security. Emits `pressed` / `released`
/// callbacks when the Fn flag toggles in isolation.
public final class FnKeyMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastFnDown = false

    public var onPressed: (@Sendable () -> Void)?
    public var onReleased: (@Sendable () -> Void)?

    public init() {}

    public func start() throws {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<FnKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handle(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            throw FnKeyMonitorError.tapCreateFailed
        }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
        runLoopSource = nil
        lastFnDown = false
    }

    public static func hasInputMonitoringPermission() -> Bool {
        // CGPreflightListenEventAccess is the canonical check on macOS 10.15+.
        return CGPreflightListenEventAccess()
    }

    public static func requestInputMonitoringPermission() {
        // Triggers the system prompt the first time; subsequent calls are no-ops
        // unless the user revokes access.
        _ = CGRequestListenEventAccess()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }
        guard type == .flagsChanged else { return }
        let isFnDown = event.flags.contains(.maskSecondaryFn)
        if isFnDown == lastFnDown { return }
        lastFnDown = isFnDown
        if isFnDown {
            onPressed?()
        } else {
            onReleased?()
        }
    }
}
#endif
