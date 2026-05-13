import AppKit
import AVFoundation
import Foundation
import WaveCore

@MainActor
final class PermissionPromptAssistant {
    static let shared = PermissionPromptAssistant()

    private var overlayController: PermissionOverlayWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activePrompt: PermissionPrompt?
    private var didPresentCurrentOverlay = false
    /// Mtime of `~/Library/Preferences/com.apple.HIToolbox.plist` captured
    /// when the user kicks off a `.fnKey` flow. We treat any later mtime
    /// bump (combined with `AppleFnUsageType == 0`) as the signal that
    /// the user actually drove the dropdown in System Settings — which
    /// is the only thing that gets HIToolbox to re-read its cache.
    private var fnPrefBaselineMtime: Date?

    init() {}

    /// Entry point that picks the right path for the prompt and current grant state.
    /// - Accessibility: opens System Settings and shows the drag-to-add overlay.
    /// - Microphone (undetermined): fires the native consent prompt only — no overlay.
    /// - Microphone (denied): opens System Settings and shows the flip-the-toggle overlay.
    /// - Fn key: opens Keyboard Settings and shows the change-the-dropdown overlay.
    func request(_ prompt: PermissionPrompt) {
        switch prompt {
        case .accessibility:
            present(prompt: .accessibility, variant: .dragToList)
        case .microphone:
            switch PermissionsProbe.microphoneStatus() {
            case .granted:
                dismiss()
            case .undetermined:
                dismiss()
                // The system permission alert (owned by tccd) takes focus while
                // it's visible. When it dismisses, macOS runs its own app-switch
                // and prefers a regular-policy app over our accessory app — so
                // whatever was previously frontmost (often Finder) wins unless
                // we re-activate *after* that switch settles. A short delay
                // before activating lets the OS finish its switch first.
                let windowToRefocus = NSApp.keyWindow ?? NSApp.mainWindow
                Task {
                    _ = await PermissionsProbe.requestMicrophone()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = windowToRefocus, window.isVisible {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            case .denied, .unknown:
                present(prompt: .microphone, variant: .toggleInList)
            }
        case .fnKey:
            fnPrefBaselineMtime = FnSystemPreference.hiToolboxPlistModificationDate()
            present(prompt: .fnKey, variant: .dropdownToValue)
        }
    }

    func present(
        prompt: PermissionPrompt,
        variant: PermissionOverlayVariant,
        hostApp: PermissionPromptHostApp = .current()
    ) {
        dismiss()
        activePrompt = prompt
        didPresentCurrentOverlay = false
        overlayController = PermissionOverlayWindowController(
            hostApp: hostApp,
            prompt: prompt,
            variant: variant
        ) { [weak self] in
            self?.dismiss()
        }
        NSWorkspace.shared.open(prompt.settingsURL)
        startTracking()
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        overlayController?.close()
        overlayController = nil
        activePrompt = nil
        didPresentCurrentOverlay = false
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
                self?.dismissIfGranted()
            }
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPosition()
            }
        }
        refreshPosition()
    }

    private func refreshPosition() {
        guard let snapshot = SettingsWindowLocator.frontmostWindow() else {
            overlayController?.hide()
            return
        }
        if didPresentCurrentOverlay {
            overlayController?.updatePosition(with: snapshot.frame, visibleFrame: snapshot.visibleFrame)
            return
        }

        overlayController?.present(
            settingsFrame: snapshot.frame,
            visibleFrame: snapshot.visibleFrame
        )
        didPresentCurrentOverlay = true
    }

    private func dismissIfGranted() {
        guard let activePrompt else { return }
        let granted: Bool
        switch activePrompt {
        case .accessibility:
            granted = PermissionsProbe.accessibilityStatus() == .granted
        case .microphone:
            granted = PermissionsProbe.microphoneStatus() == .granted
        case .fnKey:
            granted = isFnKeyToggleConfirmed()
        }
        if granted { dismiss() }
    }

    /// True when the user has driven the Press-🌐 dropdown through
    /// System Settings since this prompt was opened. Two conditions:
    /// 1. The current value is `.doNothing`.
    /// 2. The HIToolbox plist mtime has moved past the baseline we
    ///    captured when the user clicked Configure — this is what tells
    ///    us the write came from Settings (the only path that also
    ///    flushes HIToolbox's in-memory cache), not from our app or
    ///    some leftover state.
    private func isFnKeyToggleConfirmed() -> Bool {
        guard FnSystemPreference.currentFnUsageType() == .doNothing else { return false }
        guard let now = FnSystemPreference.hiToolboxPlistModificationDate() else { return false }
        guard let base = fnPrefBaselineMtime else { return false }
        return now > base
    }
}
