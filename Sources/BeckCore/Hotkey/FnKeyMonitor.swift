#if canImport(AppKit)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

public enum FnKeyMonitorError: Error {
    case missingPermission
}

/// Listens for the macOS Fn (Globe) modifier flag via NSEvent's global +
/// local flagsChanged monitors. Requires only Accessibility permission —
/// modifier-flag changes don't reveal typed characters, so macOS does
/// not gate this signal behind the Input Monitoring pane (which would
/// otherwise prompt "<app> would like to receive keystrokes from any
/// application"). Wispr Flow uses the same approach.
public final class FnKeyMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastFnDown = false

    public var onPressed: (@Sendable () -> Void)?
    public var onReleased: (@Sendable () -> Void)?

    public init() {}

    public func start() throws {
        guard globalMonitor == nil else { return }
        guard FnKeyMonitor.hasAccessibilityPermission() else {
            throw FnKeyMonitorError.missingPermission
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event: event)
            return event
        }
    }

    public func stop() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
        }
        globalMonitor = nil
        localMonitor = nil
        lastFnDown = false
    }

    public static func hasAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    private func handle(event: NSEvent) {
        // Mirror the original CGEvent semantic: .maskSecondaryFn is set
        // only for the physical Fn/Globe key, not for arrow / F1–F12
        // "function" keys that also raise NSEvent.ModifierFlags.function.
        let isFnDown = event.cgEvent?.flags.contains(.maskSecondaryFn) ?? false
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
