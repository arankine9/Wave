import AppKit
import SwiftUI
import VoxflowCore

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let prefs: PreferencesStore

    init(prefs: PreferencesStore) {
        self.prefs = prefs
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(prefs: prefs)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Voxflow Settings"
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.setContentSize(NSSize(width: 460, height: 340))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct SettingsView: View {
    let prefs: PreferencesStore
    @State private var snapshot: Preferences
    @State private var permissions: PermissionsSnapshot
    @State private var refreshTimer: Timer?

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        _snapshot = State(initialValue: prefs.value)
        _permissions = State(initialValue: PermissionsProbe.current())
    }

    var body: some View {
        Form {
            Section("Permissions") {
                permissionRow(
                    "Microphone",
                    grant: permissions.microphone,
                    pane: .microphone,
                    explainer: "Required to record audio while the hotkey is held."
                )
                permissionRow(
                    "Input Monitoring",
                    grant: permissions.inputMonitoring,
                    pane: .inputMonitoring,
                    explainer: "Required to detect the global Fn-key dictation hotkey."
                )
                permissionRow(
                    "Accessibility",
                    grant: permissions.accessibility,
                    pane: .accessibility,
                    explainer: "Required to paste cleaned text into the focused app."
                )
            }
            Section("Speech-to-text") {
                Picker("Backend", selection: $snapshot.sttBackend) {
                    ForEach(STTBackendKind.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
            }
            Section("Cleanup") {
                Picker("Mode", selection: $snapshot.cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                TextField("Ollama model", text: $snapshot.cleanupModel)
                    .disabled(snapshot.cleanupMode != .auto)
                TextField("Ollama URL", text: $snapshot.ollamaURL)
                    .disabled(snapshot.cleanupMode != .auto)
            }
            Section("Paste") {
                Picker("Mode", selection: $snapshot.pasteMode) {
                    ForEach(PasteMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }
            Section("Hotkey timing") {
                Stepper("Hold threshold: \(snapshot.holdThresholdMs)ms", value: $snapshot.holdThresholdMs, in: 100...500, step: 10)
                Stepper("Double-tap window: \(snapshot.doubleTapWindowMs)ms", value: $snapshot.doubleTapWindowMs, in: 150...500, step: 10)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 540)
        .onChange(of: snapshot) { _, newValue in
            prefs.update { $0 = newValue }
        }
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    permissions = PermissionsProbe.current()
                }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    @ViewBuilder
    private func permissionRow(
        _ title: String,
        grant: PermissionGrant,
        pane: PermissionsProbe.SettingsPane,
        explainer: String
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: grant == .granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(grant == .granted ? .green : .orange)
                .imageScale(.large)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(explainer).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if grant != .granted {
                Button("Open Settings") {
                    PermissionsProbe.openSystemSettings(pane)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }
}
