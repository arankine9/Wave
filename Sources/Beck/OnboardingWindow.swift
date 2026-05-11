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
        w.setContentSize(NSSize(width: 520, height: 620))
        w.center()
        w.isReleasedWhenClosed = false
        window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case permissions
    case fnKey
    case menuBar
    case paste
    case done

    var isFirst: Bool { self == .permissions }
    var isLast: Bool { self == .done }
}

private struct OnboardingView: View {
    let onClose: () -> Void
    @State private var step: OnboardingStep = .permissions
    @State private var snapshot: PermissionsSnapshot = PermissionsProbe.current()
    @State private var refreshTimer: Timer?
    @State private var fnPressedOnce: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepView
                    .id(step)
                    .transition(stepTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 12)
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: step)

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 22)
        }
        .frame(width: 520, height: 620)
        .background(.background)
        .onAppear {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in
                    snapshot = PermissionsProbe.current()
                }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .permissions: PermissionsStep(snapshot: snapshot)
        case .fnKey:       FnKeyStep(pressedOnce: $fnPressedOnce)
        case .menuBar:     MenuBarStep()
        case .paste:       PasteStep()
        case .done:        DoneStep()
        }
    }

    private var stepTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .move(edge: .trailing)),
            removal: .opacity.combined(with: .move(edge: .leading))
        )
    }

    @ViewBuilder
    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Capsule()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: s == step ? 16 : 6, height: 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: step)
                }
            }

            HStack(spacing: 10) {
                if !step.isFirst {
                    Button("Back") { advance(by: -1) }
                        .controlSize(.regular)
                        .keyboardShortcut(.cancelAction)
                } else {
                    Color.clear.frame(width: 1, height: 1)
                }
                Spacer()
                Button(action: { primaryAction() }) {
                    Text(primaryLabel)
                        .frame(minWidth: 96)
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)
            }
        }
    }

    private var primaryLabel: String {
        step.isLast ? "Get started" : "Next"
    }

    private var allGranted: Bool {
        snapshot.microphone == .granted
            && snapshot.accessibility == .granted
    }

    private var primaryDisabled: Bool {
        if step == .permissions && !allGranted { return true }
        if step == .fnKey && !fnPressedOnce { return true }
        return false
    }

    private func primaryAction() {
        if step.isLast {
            onClose()
            return
        }
        advance(by: 1)
    }

    private func advance(by delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) {
            step = next
        }
    }
}

// MARK: - Step 1: Permissions

private struct PermissionsStep: View {
    let snapshot: PermissionsSnapshot

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 56, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                Text("Welcome").font(.title2.weight(.semibold))
                Text("Beck needs your microphone to capture audio. Accessibility is needed to know when the Fn key is pressed and to paste text.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
            }

            VStack(spacing: 10) {
                row("Microphone", "Records audio while the hotkey is held",
                    grant: snapshot.microphone, pane: .microphone)
                row("Accessibility", "Detects the global Fn-key hotkey and pastes cleaned text",
                    grant: snapshot.accessibility, pane: .accessibility)
            }
            .padding(.horizontal, 18)

            Spacer(minLength: 0)

            Text("Tip: you can find settings and other controls in the menu bar.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
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

// MARK: - Shared header

private struct StepHeader: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 38, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
        }
    }
}

// MARK: - Step 2: Fn-key push-to-talk

/// Listens for the physical Fn (Globe) modifier so the onboarding tutorial
/// can animate in response to real key presses. Decoupled from the main
/// FnKeyMonitor — adding a second NSEvent monitor doesn't consume events,
/// so the real dictation pipeline still runs while the user "tries it".
private final class FnLiveListener: ObservableObject {
    @Published var pressed: Bool = false
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastDown = false

    func start() {
        guard globalMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        lastDown = false
        pressed = false
    }

    deinit { stop() }

    private func handle(_ event: NSEvent) {
        let down = event.cgEvent?.flags.contains(.maskSecondaryFn) ?? false
        if down == lastDown { return }
        lastDown = down
        pressed = down
    }
}

private struct FnKeyStep: View {
    @Binding var pressedOnce: Bool
    @State private var pressed = false
    @StateObject private var live = FnLiveListener()

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(
                icon: "keyboard",
                title: "Hold Fn, then talk",
                subtitle: "Press and hold Fn, speak, then release. Beck transcribes and pastes the cleaned text anywhere."
            )

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                VStack(spacing: 20) {
                    FnKeyView(pressed: pressed)

                    WaveformView(active: pressed)
                        .frame(height: 32)

                    if !pressedOnce {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("hold the Fn key")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
                .padding(20)
                .animation(.easeInOut(duration: 0.25), value: pressedOnce)
            }
            .frame(maxHeight: .infinity)

            Text("Tip: Double-tap Fn to lock dictation on; a single tap stops it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear { live.start() }
        .onDisappear { live.stop() }
        .onChange(of: live.pressed) { _, isDown in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) {
                pressed = isDown
            }
            if isDown && !pressedOnce {
                pressedOnce = true
            }
        }
    }
}

private struct FnKeyView: View {
    let pressed: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .frame(width: 104, height: 64)
                .blur(radius: 6)
                .opacity(pressed ? 0.15 : 0.55)
                .offset(y: pressed ? 2 : 6)

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: pressed
                            ? [Color.accentColor.opacity(0.85), Color.accentColor]
                            : [Color.gray.opacity(0.14), Color.gray.opacity(0.32)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                )
                .frame(width: 104, height: 64)
                .offset(y: pressed ? 4 : 0)
                .shadow(color: pressed ? Color.accentColor.opacity(0.45) : .clear, radius: 14)

            Text("fn")
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(pressed ? Color.white : .secondary)
                .offset(y: pressed ? 4 : 0)
        }
        .scaleEffect(pressed ? 0.97 : 1)
        .frame(height: 80)
    }
}

private struct WaveformView: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 4) {
                ForEach(0..<22, id: \.self) { i in
                    Capsule()
                        .fill(active ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 4, height: barHeight(at: i, time: t))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: active)
        }
    }

    private func barHeight(at i: Int, time: Double) -> CGFloat {
        let base: Double = active ? 26 : 5
        let phase = Double(i) * 0.55 + time * 5.5
        let envelope = 0.35 + 0.65 * abs(sin(phase))
        return CGFloat(max(4, base * envelope))
    }
}

// MARK: - Step 3: Menu bar

private struct MenuBarStep: View {
    @State private var iconHover = false
    @State private var showMenu = false
    @State private var hoverIndex: Int? = nil
    @State private var loop: Task<Void, Never>?

    private let menuRows: [MenuRowSpec] = [
        .init(icon: "circle.fill", color: .green, label: "Status: Idle", isStatus: true),
        .init(icon: "speaker.wave.2", label: "Test Dictation"),
        .init(icon: "gearshape", label: "Open Settings…"),
        .init(icon: "clock.arrow.circlepath", label: "Open History…"),
        .init(icon: "doc.on.clipboard", label: "Copy Diagnostics"),
        .init(icon: "power", label: "Quit Beck")
    ]

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(
                icon: "menubar.rectangle",
                title: "Beck lives in the menu bar",
                subtitle: "Beck lives in the menu bar. Click the waveform icon near the battery to test dictation, open settings, or view history."
            )

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                VStack(alignment: .trailing, spacing: 0) {
                    MenuBarMockup(highlighted: iconHover)
                        .padding(.top, 14)
                        .padding(.horizontal, 14)
                    DropdownMenu(
                        rows: menuRows,
                        hoverIndex: hoverIndex,
                        visible: showMenu
                    )
                    .padding(.trailing, 30)
                    .padding(.top, 6)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxHeight: .infinity)

            Text("\u{201C}Test Dictation\u{201D} pastes a sample so you can verify the full pipeline.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear { startLoop() }
        .onDisappear { loop?.cancel() }
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { @MainActor in
            while !Task.isCancelled {
                showMenu = false
                hoverIndex = nil
                iconHover = false
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }

                withAnimation(.easeInOut(duration: 0.22)) { iconHover = true }
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled { return }

                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { showMenu = true }

                for (i, _) in menuRows.enumerated() {
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if Task.isCancelled { return }
                    withAnimation(.easeInOut(duration: 0.18)) { hoverIndex = i }
                }

                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    showMenu = false
                    iconHover = false
                    hoverIndex = nil
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }
}

private struct MenuRowSpec {
    let icon: String
    var color: Color = .secondary
    let label: String
    var isStatus: Bool = false
}

private struct MenuBarMockup: View {
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            Image(systemName: "wifi").foregroundStyle(.secondary)
            Image(systemName: "battery.75percent").foregroundStyle(.secondary)
            ZStack {
                if highlighted {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .frame(width: 24, height: 22)
                }
                Image(systemName: "waveform")
                    .foregroundStyle(highlighted ? Color.accentColor : .primary)
                    .scaleEffect(highlighted ? 1.05 : 1)
            }
            .padding(.trailing, 4)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}

private struct DropdownMenu: View {
    let rows: [MenuRowSpec]
    let hoverIndex: Int?
    let visible: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                if idx == 1 || idx == rows.count - 1 {
                    Divider().padding(.horizontal, 6)
                }
                rowView(row, hovered: hoverIndex == idx)
            }
        }
        .padding(.vertical, 4)
        .frame(width: 230, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10))
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .opacity(visible ? 1 : 0)
        .scaleEffect(visible ? 1 : 0.92, anchor: .topTrailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func rowView(_ row: MenuRowSpec, hovered: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.icon)
                .foregroundStyle(row.color)
                .font(row.isStatus ? .system(size: 8) : .caption)
                .frame(width: 14)
            Text(row.label)
                .font(.callout)
                .foregroundStyle(hovered ? Color.white : .primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovered ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Step 4: Pasted into focused app

private struct PasteStep: View {
    enum Phase { case empty, spoken, pasted }

    @State private var phase: Phase = .empty
    @State private var loop: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 22) {
            StepHeader(
                icon: "text.cursor",
                title: "Cleaned text drops into your focused app",
                subtitle: "A local model (Ollama) cleans up your transcript. Beck pastes the result wherever your cursor is."
            )

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.primary.opacity(0.04))

                VStack(alignment: .leading, spacing: 18) {
                    sectionLabel(icon: "mic.fill", text: "You said")
                    Text("\u{201C}open paren self dot user underscore id close paren\u{201D}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .opacity(phase == .empty ? 0 : 1)
                        .animation(.easeInOut(duration: 0.3), value: phase)

                    Divider()

                    sectionLabel(icon: "text.cursor", text: "Pasted into your app")
                    EditorMockup(text: phase == .pasted ? "self.user_id" : "")
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)

            Text("Works in any text field — terminals, code editors, chat windows, anywhere.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .onAppear { startLoop() }
        .onDisappear { loop?.cancel() }
    }

    @ViewBuilder
    private func sectionLabel(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { @MainActor in
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: 0.3)) { phase = .empty }
                try? await Task.sleep(nanoseconds: 700_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.4)) { phase = .spoken }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.4)) { phase = .pasted }
                try? await Task.sleep(nanoseconds: 2_200_000_000)
            }
        }
    }
}

private struct EditorMockup: View {
    let text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.10))
                )

            HStack(spacing: 0) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .transition(.opacity)
                BlinkingCursor()
                Spacer(minLength: 0)
            }
            .padding(12)
        }
        .frame(height: 64)
    }
}

private struct BlinkingCursor: View {
    @State private var on = true

    var body: some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 2, height: 16)
            .opacity(on ? 1 : 0)
            .padding(.leading, 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}

// MARK: - Step 5: Done

private struct DoneStep: View {
    @State private var pulse = false
    @State private var checkScale: CGFloat = 0.6

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 156, height: 156)
                    .scaleEffect(pulse ? 1.10 : 1)
                Circle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 110, height: 110)
                Image(systemName: "checkmark")
                    .font(.system(size: 50, weight: .semibold))
                    .foregroundStyle(.tint)
                    .scaleEffect(checkScale)
            }
            .padding(.top, 24)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                    pulse = true
                }
                withAnimation(.spring(response: 0.5, dampingFraction: 0.55)) {
                    checkScale = 1
                }
            }

            VStack(spacing: 8) {
                Text("You're all set")
                    .font(.title.weight(.semibold))
                Text("Hold Fn anywhere on macOS to dictate. Use the menu bar to tweak settings or browse history.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }

            Spacer(minLength: 0)
        }
    }
}
