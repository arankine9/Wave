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

    init(prefs: PreferencesStore) {
        self.prefs = prefs
        _snapshot = State(initialValue: prefs.value)
    }

    var body: some View {
        Form {
            Section("Speech-to-text") {
                Picker("Backend", selection: $snapshot.sttBackend) {
                    ForEach(STTBackendKind.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
            }
            Section("Cleanup") {
                TextField("Ollama model", text: $snapshot.cleanupModel)
                TextField("Ollama URL", text: $snapshot.ollamaURL)
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
        .frame(width: 460, height: 340)
        .onChange(of: snapshot) { _, newValue in
            prefs.update { $0 = newValue }
        }
    }
}
