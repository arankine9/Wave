import AppKit
import SwiftUI
import VoxflowCore

@MainActor
final class StatusPillController {
    private var window: NSPanel?
    private let appState: AppState
    private let model = StatusPillModel()

    init(appState: AppState) {
        self.appState = appState
        appState.onStatusChange = { [weak self] status in
            Task { @MainActor in self?.apply(status: status) }
        }
        appState.onPartialChange = { [weak self] text in
            Task { @MainActor in self?.model.partial = text }
        }
    }

    private func apply(status: DictationStatus) {
        model.status = status
        switch status {
        case .recording, .transcribing, .cleaning, .pasting:
            show()
        case .idle, .error:
            // Linger briefly on errors, then hide.
            if case .error = status {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    self.hide()
                }
            } else {
                hide()
            }
        }
    }

    private func show() {
        if let window {
            window.orderFrontRegardless()
            return
        }
        let view = StatusPillView(model: model)
        let host = NSHostingController(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        positionAtBottomCenter(panel)
        panel.orderFrontRegardless()
        window = panel
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func hide() {
        window?.orderOut(nil)
    }
}

@MainActor
private final class StatusPillModel: ObservableObject {
    @Published var status: DictationStatus = .idle
    @Published var partial: String = ""
}

private struct StatusPillView: View {
    @ObservedObject var model: StatusPillModel

    var body: some View {
        HStack(spacing: 10) {
            indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                if !model.partial.isEmpty {
                    Text(model.partial)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        .frame(width: 280, height: 60)
    }

    private var label: String { model.status.displayName }

    @ViewBuilder
    private var indicator: some View {
        ZStack {
            Circle().fill(color).frame(width: 12, height: 12)
            if case .recording = model.status {
                Circle()
                    .stroke(color.opacity(0.6), lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .scaleEffect(scale)
                    .opacity(2 - scale)
                    .animation(.easeOut(duration: 1.0).repeatForever(autoreverses: false), value: scale)
                    .onAppear { scale = 1.6 }
            }
        }
        .frame(width: 24, height: 24)
    }

    @State private var scale: CGFloat = 1.0

    private var color: Color {
        switch model.status {
        case .recording:    return .red
        case .transcribing: return .orange
        case .cleaning:     return .yellow
        case .pasting:      return .green
        case .error:        return .pink
        case .idle:         return .gray
        }
    }
}
