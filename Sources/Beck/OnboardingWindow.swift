import AppKit
import SwiftUI
import BeckCore

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?

    func showIfPermissionsMissing() {
        let snapshot = PermissionsProbe.current()
        let allGranted = snapshot.microphone == .granted
            && snapshot.accessibility == .granted
        guard !allGranted else { return }
        show()
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(onClose: { [weak self] in
            self?.window?.orderOut(nil)
        })
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Welcome to Beck"
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.setContentSize(NSSize(width: 480, height: 540))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct OnboardingView: View {
    let onClose: () -> Void
    @State private var snapshot: PermissionsSnapshot = PermissionsProbe.current()
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text("Welcome to Beck").font(.title2.weight(.semibold))
                Text("Hold the **Fn** key, talk, release. Cleaned text appears in your focused app.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 24)
            }

            VStack(spacing: 10) {
                row("Microphone", "Records audio while the hotkey is held",
                    grant: snapshot.microphone, pane: .microphone)
                row("Accessibility", "Detects the global Fn-key hotkey and pastes cleaned text",
                    grant: snapshot.accessibility, pane: .accessibility)
            }
            .padding(.horizontal, 18)

            VStack(spacing: 6) {
                Text("Tip: double-tap Fn to lock dictation on, single tap to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Beck lives in the menu bar near the battery — there's no dock icon.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            Button(action: onClose) {
                Text(allGranted ? "Get started" : "Close")
                    .frame(minWidth: 160)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 24)
        .frame(width: 480, height: 540)
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    snapshot = PermissionsProbe.current()
                }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var allGranted: Bool {
        snapshot.microphone == .granted
            && snapshot.accessibility == .granted
    }

    @ViewBuilder
    private func row(
        _ title: String, _ explainer: String,
        grant: PermissionGrant, pane: PermissionsProbe.SettingsPane
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: grant == .granted ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(grant == .granted ? .green : .secondary)
                .font(.title3)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(explainer).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if grant != .granted {
                Button("Grant") {
                    PermissionPromptAssistant.shared.request(prompt(for: pane))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func prompt(for pane: PermissionsProbe.SettingsPane) -> PermissionPrompt {
        switch pane {
        case .microphone: .microphone
        case .accessibility: .accessibility
        }
    }
}
