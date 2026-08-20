import AppKit
import WaveCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private var historyController: HistoryWindowController?
    private var pillController: StatusPillController?
    private var onboardingController: OnboardingWindowController?
    private let appState = AppState()
    private let prefs = PreferencesStore()
    private var fnMonitor: FnKeyMonitor?
    private var hotkeyController: HotkeyController?
    private var orchestrator: DictationOrchestrator?
    private let history = HistoryLogger(file: HistoryLogger.defaultURL())
    /// Remembers the last dictation so Ctrl+Cmd+V can re-paste it. Seeded from
    /// the history log at launch (see `installDictationPipeline`).
    private var lastDictation = LastDictationStore()
    private var repasteHotKey: RepasteHotKey?
    /// The paster the orchestrator pastes through, retained so the repaste
    /// hotkey can reuse it.
    private var paster: Paster?

    private var pipelineInstalled = false
    private var permissionRetryTimer: Timer?
    private var parakeet: ParakeetBackend?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching")

        // Reclaim the Fn key from macOS as early as possible. This is
        // load-bearing — without it, pressing Fn fires the emoji
        // picker / Start Dictation overlay before our CGEventTap can
        // do anything. See `FnSystemPreference` for *why* a plist
        // write alone isn't enough and why we MUST pair it with the
        // distributed-notification post that lives inside
        // `setFnUsageType`. Do not remove either half.
        let prior = FnSystemPreference.enforceDoNothing()
        if prior != nil && prior != .doNothing {
            debugLog("Reset AppleFnUsageType from \(prior!) → doNothing")
        }

        let settings = SettingsWindowController(prefs: prefs)
        settingsController = settings
        AppMenu.install(openSettings: { [weak settings] in settings?.show() })
        let historyWindow = HistoryWindowController(history: history)
        historyController = historyWindow
        pillController = StatusPillController(appState: appState)
        statusController = StatusItemController(
            appState: appState,
            openSettings: { [weak settings] in settings?.show() },
            openHistory: { [weak historyWindow] in historyWindow?.show() }
        )
        statusController?.install()

        installDictationPipeline()
        installRepasteHotKey()
        startPermissionRetry()

        let onboarding = OnboardingWindowController()
        onboardingController = onboarding
        onboarding.showIfSetupIncomplete()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor?.stop()
        repasteHotKey?.unregister()
        statusController?.uninstall()
        permissionRetryTimer?.invalidate()
    }

    private func installDictationPipeline() {
        let current = prefs.value
        // Verbose log when WAVE_PARAKEET_LOG=1 — stderr, visible from the
        // terminal that launched the .app (or from Console.app).
        let verbose = ProcessInfo.processInfo.environment["WAVE_PARAKEET_LOG"] == "1"
        let prefsRef = prefs
        let parakeet = ParakeetBackend(config: .init(
            verboseLog: verbose,
            microphoneChoiceProvider: { prefsRef.value.microphoneChoice }
        ))
        let state = appState
        parakeet.levelObserver = { level in
            state.setAudioLevel(level)
        }
        self.parakeet = parakeet
        let backend: STTBackend = parakeet
        Task.detached(priority: .utility) {
            try? await parakeet.prewarm()
        }

        let paster = PasterFactory.make(mode: current.pasteMode)
        self.paster = paster

        // Seed the repaste buffer from the last logged dictation so Ctrl+Cmd+V
        // works immediately after launch, then keep it current by recording
        // alongside the history log. Build the composite before handing it to
        // the orchestrator so both share this exact store instance.
        let lastDictation = LastDictationStore(text: history.recent(limit: 1).last?.finalText)
        self.lastDictation = lastDictation

        let orchestrator = DictationOrchestrator(
            backend: backend,
            paster: paster,
            appState: appState,
            logger: CompositeDictationLogger([history, lastDictation]),
            media: OutputMuteMediaController(),
            mediaMuteEnabled: { [prefsRef] in prefsRef.value.muteAudioWhileRecording }
        )
        self.orchestrator = orchestrator

        let controller = HotkeyController(
            clock: RealClock(),
            holdThresholdMs: current.holdThresholdMs,
            doubleTapWindowMs: current.doubleTapWindowMs
        )
        controller.onEvent = { event in
            Self.staticDebugLog("hotkey event: \(event)")
            Task { await orchestrator.handle(event) }
        }
        hotkeyController = controller

        tryStartFnMonitor()
    }

    /// Registers the Ctrl+Cmd+V global hotkey that re-pastes the most recent
    /// dictation. Registration needs no permission, so it can happen eagerly
    /// at launch; the paste it triggers needs Accessibility, same as ordinary
    /// dictation, and is handled (and logged) if that's missing.
    private func installRepasteHotKey() {
        let hotKey = RepasteHotKey()
        hotKey.onPressed = { [weak self] in
            Task { @MainActor in self?.repasteLastDictation() }
        }
        repasteHotKey = hotKey
        if hotKey.register() {
            debugLog("repaste hotkey registered (Ctrl+Cmd+V → last dictation)")
        } else {
            // Almost always means another running app already owns Ctrl+Cmd+V
            // as a global shortcut. Dictation is unaffected; only repaste is.
            debugLog("repaste hotkey FAILED to register — Ctrl+Cmd+V may be taken by another app")
        }
    }

    private func repasteLastDictation() {
        guard let text = lastDictation.text, !text.isEmpty else {
            debugLog("repaste: nothing dictated yet; ignoring Ctrl+Cmd+V")
            return
        }
        guard let paster else { return }
        // The user is still physically holding Ctrl+Cmd+V the instant this
        // fires. Wait a beat for the chord to lift before synthesizing Cmd+V —
        // otherwise the held Control rides along and the frontmost app sees
        // Ctrl+Cmd+V (not a plain paste). 60ms comfortably outlasts a normal
        // tap-and-release without being perceptible.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            do {
                try paster.paste(text)
            } catch {
                self?.debugLog("repaste: paste failed: \(error)")
            }
        }
    }

    /// Attempts to install the global Fn key monitor. Returns true once it
    /// succeeds (or has already been installed). Throws nothing — the caller
    /// inspects the returned bool to decide whether to retry later.
    @discardableResult
    private func tryStartFnMonitor() -> Bool {
        if fnMonitor != nil {
            return true
        }
        guard FnKeyMonitor.hasAccessibilityPermission() else {
            debugLog("tryStartFnMonitor: Accessibility NOT granted (AXIsProcessTrusted=false). Open System Settings → Privacy & Security → Accessibility and re-enable Wave. After every rebuild the ad-hoc signature changes, so the existing toggle may need to be turned off and back on.")
            appState.setStatus(.error("Grant Accessibility in Privacy & Security"))
            return false
        }
        let monitor = FnKeyMonitor()
        monitor.onPressed = { [weak hc = hotkeyController] in
            Self.staticDebugLog("fn DOWN")
            hc?.handlePressed()
        }
        monitor.onReleased = { [weak hc = hotkeyController] in
            Self.staticDebugLog("fn UP")
            hc?.handleReleased()
        }
        do {
            try monitor.start()
            fnMonitor = monitor
            pipelineInstalled = true
            debugLog("tryStartFnMonitor: Fn monitor installed; dictation is live")
            if case .error = appState.status {
                appState.setStatus(.idle)
            }
            return true
        } catch FnKeyMonitorError.missingPermission {
            debugLog("tryStartFnMonitor: start() reported missingPermission")
            appState.setStatus(.error("Grant Accessibility in Privacy & Security"))
            return false
        } catch {
            debugLog("tryStartFnMonitor: start() threw \(error)")
            appState.setStatus(.error("Fn monitor: \(error)"))
            return false
        }
    }

    /// Polls Accessibility permission every second until the Fn monitor is
    /// installed. macOS TCC doesn't notify processes when a permission
    /// changes, so polling is the only portable option short of restart.
    private func startPermissionRetry() {
        guard permissionRetryTimer == nil else { return }
        permissionRetryTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.tryStartFnMonitor() {
                    self.permissionRetryTimer?.invalidate()
                    self.permissionRetryTimer = nil
                }
            }
        }
    }

    private func debugLog(_ message: String) {
        Self.staticDebugLog(message)
    }

    nonisolated static func staticDebugLog(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        FileHandle.standardError.write(Data("[wave \(ts)] \(message)\n".utf8))
    }
}
