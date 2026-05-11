import AppKit
import SwiftUI
import BeckCore

@MainActor
final class HistoryWindowController {
    private var window: NSWindow?
    private let history: HistoryLogger

    init(history: HistoryLogger) {
        self.history = history
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HistoryView(history: history)
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = "Beck History"
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        w.setContentSize(NSSize(width: 560, height: 420))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct HistoryView: View {
    let history: HistoryLogger
    @State private var lines: [HistoryLine] = []
    @State private var query: String = ""
    @State private var didExport = false

    private var filtered: [HistoryLine] {
        guard !query.isEmpty else { return lines }
        let q = query.lowercased()
        return lines.filter {
            $0.finalText.lowercased().contains(q)
                || $0.rawTranscript.lowercased().contains(q)
                || $0.path.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Last 50 dictations").font(.headline)
                Spacer()
                TextField("Search…", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Button(didExport ? "Copied" : "Copy as JSON") { exportJSON() }
                    .buttonStyle(.bordered)
                Button("Reveal File") { revealInFinder() }
                    .buttonStyle(.bordered)
                Button("Refresh", action: refresh).buttonStyle(.bordered)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView(
                    lines.isEmpty ? "No dictations yet" : "No matches",
                    systemImage: lines.isEmpty ? "waveform.slash" : "magnifyingglass",
                    description: Text(lines.isEmpty
                        ? "Hold the Fn key to dictate, and entries will appear here."
                        : "No history entries match '\(query)'.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(Array(filtered.enumerated()), id: \.offset) { _, entry in
                    HistoryRow(entry: entry)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 540, minHeight: 360)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        lines = history.recent(limit: 50).reversed()
    }

    private func exportJSON() {
        guard let data = try? JSONEncoder().encode(filtered),
              let s = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        didExport = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didExport = false
        }
    }

    private func revealInFinder() {
        let url = HistoryLogger.defaultURL()
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryLine
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.timestampISO).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                pathBadge
                Text("\(entry.sttMs)+\(entry.cleanupMs)+\(entry.pasteMs)ms")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(didCopy ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                    didCopy = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        didCopy = false
                    }
                }
                .controlSize(.mini)
                .buttonStyle(.bordered)
            }
            Text(entry.finalText)
                .font(.system(.body, design: .monospaced))
                .lineLimit(3)
                .textSelection(.enabled)
            if !entry.rawTranscript.isEmpty && entry.rawTranscript != entry.finalText {
                Text("raw: " + entry.rawTranscript)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var pathBadge: some View {
        Text(entry.path.uppercased())
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(badgeColor.opacity(0.18), in: Capsule())
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        entry.path == "skipped" ? .green : .blue
    }
}
