import AppKit
import Foundation
import BeckCore

@MainActor
enum Diagnostics {
    /// Snapshots everything a user (or you) would want to see when filing a
    /// bug report: app + macOS version, current preferences, permission
    /// status, Ollama reachability, and the last few history entries.
    /// Result is copied to the clipboard.
    static func copyToClipboard(prefs: PreferencesStore) async {
        let report = await render(prefs: prefs)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    static func render(prefs: PreferencesStore) async -> String {
        let perms = PermissionsProbe.current()
        let p = prefs.value
        var ollamaLine = "skipped (cleanup mode = \(p.cleanupMode.rawValue))"
        if p.cleanupMode == .auto, let url = URL(string: p.ollamaURL) {
            let h = await OllamaHealthProbe.check(baseURL: url, wantedModel: p.cleanupModel)
            switch h.server {
            case .reachable:
                ollamaLine = h.modelAvailable
                    ? "reachable, '\(p.cleanupModel)' available"
                    : "reachable, '\(p.cleanupModel)' missing (have: \(h.availableModels.joined(separator: ", ")))"
            case .unreachable(let why):
                ollamaLine = "unreachable: \(why)"
            }
        }

        let lines = [
            "Beck diagnostics",
            "===================",
            "version:        \(BeckVersion.current)",
            "macOS:          \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "Preferences",
            "  stt backend:    \(p.sttBackend.rawValue)",
            "  cleanup mode:   \(p.cleanupMode.rawValue)",
            "  cleanup model:  \(p.cleanupModel)",
            "  ollama url:     \(p.ollamaURL)",
            "  paste mode:     \(p.pasteMode.rawValue)",
            "  hold ms:        \(p.holdThresholdMs)",
            "  doubletap ms:   \(p.doubleTapWindowMs)",
            "",
            "Permissions",
            "  microphone:     \(perms.microphone.rawValue)",
            "  accessibility:  \(perms.accessibility.rawValue)",
            "",
            "Ollama:           \(ollamaLine)",
            "Voxtral env set:  \(ProcessInfo.processInfo.environment["BECK_VOXTRAL_PYTHON"] ?? "no")",
            "",
            "History file:     \(HistoryLogger.defaultURL().path)",
        ]
        return lines.joined(separator: "\n")
    }
}
