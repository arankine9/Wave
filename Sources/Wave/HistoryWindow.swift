import AppKit
import SwiftUI
import WaveCore

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
        w.title = "History"
        w.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        w.collectionBehavior = [.fullScreenNone]
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        let toolbar = NSToolbar(identifier: "wave.history.toolbar")
        toolbar.showsBaselineSeparator = false
        w.toolbarStyle = .unified
        w.toolbar = toolbar
        w.setContentSize(NSSize(width: 600, height: 560))
        w.standardWindowButton(.zoomButton)?.isEnabled = false
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Root view

private struct HistoryView: View {
    let history: HistoryLogger
    @State private var lines: [HistoryLine] = []
    @State private var query: String = ""
    @State private var now: Date = Date()
    @State private var searching: Bool = false
    @FocusState private var searchFocused: Bool

    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

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
        ZStack(alignment: .top) {
            HistoryBackground()
            content
            header
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 560, minHeight: 440)
        .onAppear { reload() }
        .onReceive(tick) { _ in
            now = Date()
            reload()
        }
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            emptyState
                .padding(.top, 52)
        } else {
            cardList
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            floatingControls
        }
        .padding(.leading, 78)
        .padding(.trailing, 14)
        .padding(.top, 10)
        .frame(height: 52, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: searching)
    }

    @ViewBuilder
    private var floatingControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    searchControl
                    overflowMenu
                }
            }
        } else {
            HStack(spacing: 8) {
                searchControl
                overflowMenu
            }
        }
    }

    @ViewBuilder
    private var searchControl: some View {
        if searching {
            SearchPill(
                text: $query,
                focusBinding: $searchFocused,
                onDismiss: dismissSearch
            )
            .frame(maxWidth: 220)
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity),
                removal: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity)
            ))
            .onChange(of: searchFocused) { _, focused in
                if !focused && query.isEmpty {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                        searching = false
                    }
                }
            }
        } else {
            Button {
                searching = true
                DispatchQueue.main.async { searchFocused = true }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .help("Search")
            .waveGlassCircle()
            .transition(.asymmetric(
                insertion: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity),
                removal: .scale(scale: 0.85, anchor: .trailing).combined(with: .opacity)
            ))
        }
    }

    private func dismissSearch() {
        query = ""
        searchFocused = false
        searching = false
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                copyAllAsJSON()
            } label: {
                Label("Copy all as JSON", systemImage: "curlybraces")
            }
            Button {
                revealInFinder()
            } label: {
                Label("Reveal log in Finder", systemImage: "folder")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 30, height: 30)
        .contentShape(Circle())
        .waveGlassCircle()
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                Image(systemName: lines.isEmpty ? "waveform" : "magnifyingglass")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 14, y: 4)

            VStack(spacing: 5) {
                Text(lines.isEmpty ? "No dictations yet" : "No matches")
                    .font(.system(size: 14, weight: .semibold))
                Text(lines.isEmpty
                     ? "Hold the Fn key to dictate. Entries will appear here."
                     : "Nothing in history matches \u{201C}\(query)\u{201D}.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var cardList: some View {
        ScrollView {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: ScrollOffsetKey.self,
                    value: proxy.frame(in: .named("history.scroll")).minY
                )
            }
            .frame(height: 0)

            LazyVStack(spacing: 8) {
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, entry in
                    HistoryCard(entry: entry, now: now, query: query)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 62)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .coordinateSpace(name: "history.scroll")
        .onPreferenceChange(ScrollOffsetKey.self) { offset in
            if searching && query.isEmpty && offset < -10 {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
                    searching = false
                }
                searchFocused = false
            }
        }
    }

    private func reload() {
        let next = Array(history.recent(limit: 50).reversed())
        if next != lines { lines = next }
    }

    private func copyAllAsJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(filtered),
              let s = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
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

// MARK: - Card

private struct HistoryCard: View {
    let entry: HistoryLine
    let now: Date
    let query: String
    @State private var didCopy = false
    @State private var showRaw = false
    @State private var hovered = false

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private var date: Date? { Self.isoParser.date(from: entry.timestampISO) }

    private var hasRaw: Bool {
        !entry.rawTranscript.isEmpty && entry.rawTranscript != entry.finalText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(RelativeTime.string(date, now))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help(date.map { $0.formatted(date: .abbreviated, time: .standard) } ?? entry.timestampISO)

                pathBadge

                Spacer(minLength: 8)

                latencyChip
                    .opacity(hovered ? 1 : 0.6)

                copyButton
            }

            Text(SearchHighlight.attributed(entry.finalText, query: query))
                .font(.system(size: 13.5))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if hasRaw {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showRaw.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(showRaw ? 90 : 0))
                        Text(showRaw ? "Hide original" : "Show original")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if showRaw {
                    Text(SearchHighlight.attributed(entry.rawTranscript, query: query))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(hovered ? 0.12 : 0.06), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(hovered ? 0.07 : 0.04), radius: hovered ? 6 : 3, y: 1)
        .animation(.easeInOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Copy text") { copyText() }
            Button("Copy entry as JSON") { copyEntryJSON() }
        }
    }

    private var pathBadge: some View {
        let cleaned = entry.path.lowercased() != "skipped"
        let color: Color = cleaned
            ? Color(red: 0.32, green: 0.58, blue: 1.00)
            : Color(red: 0.20, green: 0.74, blue: 0.50)
        let label = cleaned ? "Cleaned" : "Raw"
        return HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.2)
        }
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule(style: .continuous))
        .overlay(Capsule(style: .continuous).strokeBorder(color.opacity(0.30), lineWidth: 0.5))
        .foregroundStyle(color)
    }

    private var latencyChip: some View {
        let total = entry.sttMs + entry.cleanupMs + entry.pasteMs
        return Text("\(total) ms")
            .font(.system(size: 10, design: .monospaced).weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .help("STT \(entry.sttMs) ms · Cleanup \(entry.cleanupMs) ms · Paste \(entry.pasteMs) ms")
    }

    private var copyButton: some View {
        Button(action: copyText) {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .frame(width: 26, height: 22)
                .background(
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.green.opacity(didCopy ? 0.16 : 0))
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(didCopy ? 0 : 0.10), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Copy text")
        .animation(.easeInOut(duration: 0.18), value: didCopy)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.finalText, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            didCopy = false
        }
    }

    private func copyEntryJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entry),
              let s = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// MARK: - Search pill

private struct SearchPill: View {
    @Binding var text: String
    var focusBinding: FocusState<Bool>.Binding
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused(focusBinding)
                .font(.system(size: 12.5))
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
                .onSubmit { focusBinding.wrappedValue = false }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 30)
        .waveGlassCapsule()
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(focusBinding.wrappedValue ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 0.6)
        )
        .animation(.easeInOut(duration: 0.15), value: focusBinding.wrappedValue)
    }
}

// MARK: - Scroll tracking

private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Liquid glass helpers

private extension View {
    @ViewBuilder
    func waveGlassCircle() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Circle())
        } else {
            self
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    func waveGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule(style: .continuous))
        } else {
            self
                .background(.ultraThinMaterial, in: Capsule(style: .continuous))
                .overlay(Capsule(style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        }
    }
}

// MARK: - Background

private struct HistoryBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.regularMaterial)
            RadialGradient(
                colors: [Color.blue.opacity(0.10), .clear],
                center: UnitPoint(x: 0.05, y: -0.05),
                startRadius: 10, endRadius: 440
            )
            RadialGradient(
                colors: [Color.purple.opacity(0.09), .clear],
                center: UnitPoint(x: 0.95, y: 1.05),
                startRadius: 10, endRadius: 420
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Search highlight

private enum SearchHighlight {
    static func attributed(_ text: String, query: String) -> AttributedString {
        var attr = AttributedString(text)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return attr }

        var cursor = text.startIndex
        while cursor < text.endIndex,
              let range = text.range(of: q, options: .caseInsensitive, range: cursor..<text.endIndex) {
            if let lower = AttributedString.Index(range.lowerBound, within: attr),
               let upper = AttributedString.Index(range.upperBound, within: attr) {
                attr[lower..<upper].backgroundColor = Color.yellow.opacity(0.35)
                attr[lower..<upper].foregroundColor = Color.primary
                attr[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            }
            cursor = range.upperBound
        }
        return attr
    }
}

// MARK: - Relative time

private enum RelativeTime {
    static func string(_ date: Date?, _ now: Date) -> String {
        guard let date else { return "\u{2014}" }
        let secs = Int(max(0, now.timeIntervalSince(date)))
        if secs < 3 { return "just now" }
        if secs < 60 { return "\(secs) seconds ago" }
        let minutes = secs / 60
        if minutes == 1 { return "a minute ago" }
        if minutes < 60 { return "\(minutes) minutes ago" }
        let hours = minutes / 60
        if hours == 1 { return "an hour ago" }
        if hours < 24 { return "\(hours) hours ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        let weeks = days / 7
        if days < 30 { return weeks == 1 ? "last week" : "\(weeks) weeks ago" }
        let months = days / 30
        if days < 365 { return months == 1 ? "last month" : "\(months) months ago" }
        let years = days / 365
        return years == 1 ? "last year" : "\(years) years ago"
    }
}
