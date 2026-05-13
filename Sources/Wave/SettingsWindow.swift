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
    @State private var ollamaHealth: OllamaHealth?
    @State private var probing = false
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
                    explainer: "Required to detect the global Fn-key hotkey and paste cleaned text."
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
                if snapshot.cleanupMode == .auto {
                    healthRow
                }
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
            probeOllama()
        }
        .onChange(of: snapshot.ollamaURL) { _, _ in probeOllama() }
        .onChange(of: snapshot.cleanupModel) { _, _ in probeOllama() }
        .onDisappear { refreshTimer?.invalidate() }
    }

    @ViewBuilder
    private var healthRow: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: healthIcon)
                .foregroundStyle(healthColor)
                .imageScale(.large)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(healthTitle).font(.body.weight(.medium))
                Text(healthDetail).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(probing ? "Probing…" : "Probe") { probeOllama() }
                .disabled(probing)
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 2)
    }

    private var healthIcon: String {
        guard let h = ollamaHealth else { return "questionmark.circle" }
        switch h.server {
        case .reachable: return h.modelAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        case .unreachable: return "xmark.octagon.fill"
        }
    }

    private var healthColor: Color {
        guard let h = ollamaHealth else { return .secondary }
        switch h.server {
        case .reachable: return h.modelAvailable ? .green : .orange
        case .unreachable: return .red
        }
    }

    private var healthTitle: String {
        guard let h = ollamaHealth else { return "Ollama: probing…" }
        switch h.server {
        case .reachable:
            return h.modelAvailable
                ? "Ollama reachable, '\(snapshot.cleanupModel)' available"
                : "Ollama reachable, '\(snapshot.cleanupModel)' not pulled"
        case .unreachable(let why):
            return "Ollama unreachable: \(why)"
        }
    }

    private var healthDetail: String {
        guard let h = ollamaHealth else { return "" }
        switch h.server {
        case .reachable:
            if h.modelAvailable {
                return "Cleanup will run through Ollama. Identity-cache passes are still skipped."
            }
            let list = h.availableModels.isEmpty ? "no models pulled" : h.availableModels.joined(separator: ", ")
            return "Run `ollama pull \(snapshot.cleanupModel)` to enable LLM cleanup. Available: \(list)"
        case .unreachable:
            return "Cleanup falls back to the heuristic transformer until Ollama is reachable."
        }
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

    private func probeOllama() {
        guard snapshot.cleanupMode == .auto else { return }
        guard let url = URL(string: snapshot.ollamaURL) else { return }
        probing = true
        let model = snapshot.cleanupModel
        Task {
            let h = await OllamaHealthProbe.check(baseURL: url, wantedModel: model)
            await MainActor.run {
                ollamaHealth = h
                probing = false
            }
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
