import AppKit
import SwiftUI
import WaveCore

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
        w.title = "Wave Settings"
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
    @State private var launchAtLoginEnabled: Bool = (LaunchAtLogin.current == .enabled)
    @State private var launchAtLoginNote: String?
    @State private var inputDevices: [AudioInputDevice] = []
    @State private var seenDeviceNames: [String: String] = [:]

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        _snapshot = State(initialValue: prefs.value)
        _permissions = State(initialValue: PermissionsProbe.current())
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLoginEnabled },
                    set: { newValue in
                        switch LaunchAtLogin.setEnabled(newValue) {
                        case .success(let status):
                            launchAtLoginEnabled = (status == .enabled)
                            launchAtLoginNote = (status == .requiresApproval)
                                ? "Approve in System Settings → General → Login Items."
                                : nil
                        case .failure(let err):
                            launchAtLoginEnabled = false
                            launchAtLoginNote = "Couldn't update: \(err.localizedDescription)"
                        }
                    }
                ))
                if let launchAtLoginNote {
                    Text(launchAtLoginNote).font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Mute audio while recording", isOn: $snapshot.muteAudioWhileRecording)
                Text("Wave silences your default output (Music, Spotify, browser audio, AirPlay) while you dictate, then unmutes it when you stop. The player keeps running, so audio resumes instantly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                permissionRow(
                    "Microphone",
                    grant: permissions.microphone,
                    pane: .microphone,
                    explainer: "Required to record audio while the hotkey is held."
                )
                permissionRow(
                    "Accessibility",
                    grant: permissions.accessibility,
                    pane: .accessibility,
                    explainer: "Required to detect the global Fn-key hotkey and paste dictated text."
                )
            }
            Section("Microphone") {
                Picker("Input", selection: $snapshot.microphoneChoice) {
                    Text("Built-in microphone (Recommended)").tag(MicrophoneChoice.builtIn)
                    Text("System default").tag(MicrophoneChoice.systemDefault)
                    if !externalDevices.isEmpty {
                        Divider()
                        ForEach(externalDevices, id: \.uid) { device in
                            Text(device.name).tag(MicrophoneChoice.specific(uid: device.uid))
                        }
                    }
                    if let pinned = pinnedMissing {
                        Text("\(pinned.displayName) (disconnected)")
                            .tag(MicrophoneChoice.specific(uid: pinned.uid))
                    }
                }
                Text("External and Bluetooth microphones often capture lower-quality audio, which can hurt transcription accuracy.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            refreshInputDevices()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    permissions = PermissionsProbe.current()
                    refreshInputDevices()
                }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    private var externalDevices: [AudioInputDevice] {
        inputDevices.filter { !$0.isBuiltIn }
    }

    private var pinnedMissing: (uid: String, displayName: String)? {
        guard case .specific(let uid) = snapshot.microphoneChoice else { return nil }
        guard !externalDevices.contains(where: { $0.uid == uid }) else { return nil }
        let name = seenDeviceNames[uid] ?? "External microphone"
        return (uid, name)
    }

    private func refreshInputDevices() {
        let devices = AudioInputDevices.available()
        inputDevices = devices
        for d in devices where !d.isBuiltIn {
            seenDeviceNames[d.uid] = d.name
        }
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
                Button("Grant") {
                    PermissionPromptAssistant.shared.request(prompt(for: pane))
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 2)
    }

    private func prompt(for pane: PermissionsProbe.SettingsPane) -> PermissionPrompt {
        switch pane {
        case .microphone: .microphone
        case .accessibility: .accessibility
        }
    }
}
