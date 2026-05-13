import AppKit
import BeckCore

@MainActor
final class StatusItemController {
    private let appState: AppState
    private let openSettings: () -> Void
    private let openHistory: () -> Void
    private let runTestDictation: () -> Void
    private let copyDiagnostics: () -> Void
    private var statusItem: NSStatusItem?
    private let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
    private var animationTimer: Timer?
    private var animationStartTime: CFTimeInterval = 0
    private var currentStatus: DictationStatus = .idle
    private var smoothedLevel: CGFloat = 0
    private var lastLevelUpdate: CFTimeInterval = 0
    private static let animationFPS: Double = 30
    private static let iconSize = NSSize(width: 22, height: 16)
    private static let barCount = 5
    private static let idleHeights: [CGFloat] = [0.40, 0.70, 1.00, 0.70, 0.40]
    /// RMS speech sits roughly in 0.02…0.2; multiplier maps that into the
    /// 0…1 range used for bar heights, with the floor masking room tone.
    private static let levelGain: CGFloat = 14.0
    private static let levelFloor: CGFloat = 0.04
    /// Asymmetric envelope: snap up so transients read, decay slowly so the
    /// bars don't strobe between syllables.
    private static let attackAlpha: CGFloat = 0.55
    private static let decayAlpha: CGFloat = 0.10
    /// If no audio tap arrives within this window we treat the level signal
    /// as stale (mic muted, paused, etc.) and fall back to procedural anim.
    private static let levelStaleSeconds: CFTimeInterval = 0.4

    init(
        appState: AppState,
        openSettings: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        runTestDictation: @escaping () -> Void,
        copyDiagnostics: @escaping () -> Void
    ) {
        self.appState = appState
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.runTestDictation = runTestDictation
        self.copyDiagnostics = copyDiagnostics
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = Self.barsImage(heights: Self.idleHeights)
            button.toolTip = "Beck"
        }
        item.menu = buildMenu()
        statusItem = item

        appState.onStatusChange = { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.statusMenuItem.title = "Status: \(status.displayName)"
                self.apply(status: status)
            }
        }
        appState.onAudioLevel = { [weak self] level in
            Task { @MainActor in
                self?.applyLevel(level)
            }
        }
    }

    func uninstall() {
        stopAnimating()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    private func apply(status: DictationStatus) {
        currentStatus = status
        switch status {
        case .recording, .transcribing, .cleaning, .pasting:
            startAnimating()
        case .idle, .error:
            stopAnimating()
        }
    }

    private func applyLevel(_ raw: Float) {
        let normalized = min(1.0, max(0.0, CGFloat(raw) * Self.levelGain))
        let alpha = normalized > smoothedLevel ? Self.attackAlpha : Self.decayAlpha
        smoothedLevel += alpha * (normalized - smoothedLevel)
        lastLevelUpdate = CACurrentMediaTime()
    }

    private func startAnimating() {
        guard animationTimer == nil else { return }
        animationStartTime = CACurrentMediaTime()
        tickAnimation()
        let timer = Timer(timeInterval: 1.0 / Self.animationFPS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickAnimation()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stopAnimating() {
        animationTimer?.invalidate()
        animationTimer = nil
        smoothedLevel = 0
        lastLevelUpdate = 0
        statusItem?.button?.image = Self.barsImage(heights: Self.idleHeights)
    }

    private func tickAnimation() {
        let now = CACurrentMediaTime()
        let t = now - animationStartTime
        let levelFresh = (now - lastLevelUpdate) < Self.levelStaleSeconds
        let useRealLevel = currentStatus == .recording && levelFresh

        // Bleed the smoothed level down on idle ticks so a stray .recording
        // → .transcribing transition doesn't leave a stale tall pose.
        if !useRealLevel {
            smoothedLevel *= 0.85
        }

        let heights: [CGFloat] = (0..<Self.barCount).map { i in
            let phase = CGFloat(i) * 1.05
            if useRealLevel {
                // Each bar oscillates around the current envelope. The |sin|
                // gives crisp peaks; the gain (1.05) lets the tallest bar
                // approach the icon's full height during louder syllables.
                let osc = 0.55 + 0.45 * abs(sin(t * 9.0 + phase))
                let h = Self.levelFloor + smoothedLevel * osc * 1.05
                return min(1.0, h)
            } else {
                let a = sin(t * 8.5 + phase)
                let b = sin(t * 14.2 + phase * 1.6)
                let mixed = (a + b * 0.55) / 1.55
                return 0.5 + 0.5 * CGFloat(mixed)
            }
        }
        statusItem?.button?.image = Self.barsImage(heights: heights)
    }

    private static func barsImage(heights: [CGFloat]) -> NSImage {
        let size = iconSize
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }
        NSColor.black.setFill()
        let count = heights.count
        let barWidth: CGFloat = 2.0
        let gap: CGFloat = 1.6
        let totalWidth = CGFloat(count) * barWidth + CGFloat(count - 1) * gap
        let leftPad = (size.width - totalWidth) / 2
        let minHeight: CGFloat = barWidth
        let maxHeight: CGFloat = size.height
        let centerY = size.height / 2
        for (i, raw) in heights.enumerated() {
            let clamped = max(0.0, min(1.0, raw))
            let h = max(minHeight, clamped * maxHeight)
            let x = leftPad + CGFloat(i) * (barWidth + gap)
            let y = centerY - h / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: h)
            let path = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
            path.fill()
        }
        image.isTemplate = true
        return image
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Test Dictation (paste sample)", action: #selector(runTestAction), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Open Settings…", action: #selector(openSettingsAction), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open History…", action: #selector(openHistoryAction), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnosticsAction), keyEquivalent: "d"))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Beck", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        for item in menu.items where item.target == nil && item.action != nil {
            item.target = self
        }
        return menu
    }

    @objc private func openSettingsAction() {
        openSettings()
    }

    @objc private func openHistoryAction() {
        openHistory()
    }

    @objc private func runTestAction() {
        runTestDictation()
    }

    @objc private func copyDiagnosticsAction() {
        copyDiagnostics()
    }
}
