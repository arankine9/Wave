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
    private var testPipeline: CleanupPipeline?
    private var testPaster: Paster?
    private let history = HistoryLogger(file: HistoryLogger.defaultURL())

    private var pipelineInstalled = false
    private var permissionRetryTimer: Timer?
    private var parakeet: ParakeetBackend?

    func applicationDidFinishLaunching(_ notification: Notification) {
        debugLog("applicationDidFinishLaunching")
        SystemPrompt.assertWithinBudget()

        let settings = SettingsWindowController(prefs: prefs)
        settingsController = settings
        AppMenu.install(openSettings: { [weak settings] in settings?.show() })
        let historyWindow = HistoryWindowController(history: history)
        historyController = historyWindow
        pillController = StatusPillController(appState: appState)
        statusController = StatusItemController(
            appState: appState,
            openSettings: { [weak settings] in settings?.show() },
            openHistory: { [weak historyWindow] in historyWindow?.show() },
            runTestDictation: { [weak self] in self?.runTestDictation() },
            copyDiagnostics: { [weak self] in
                guard let self else { return }
                Task { await Diagnostics.copyToClipboard(prefs: self.prefs) }
            }
        )
        statusController?.install()

        installDictationPipeline()
        startPermissionRetry()

        let onboarding = OnboardingWindowController()
        onboardingController = onboarding
        onboarding.showIfSetupIncomplete()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor?.stop()
        statusController?.uninstall()
        permissionRetryTimer?.invalidate()
    }

    private func runTestDictation() {
        guard let pipeline = testPipeline, let paster = testPaster else { return }
        let sample = "open paren self dot user underscore id close paren"
        appState.setStatus(.cleaning)
        Task { [weak self] in
            do {
                let result = try await pipeline.run(rawTranscript: sample)
                self?.appState.setStatus(.pasting)
                try paster.paste(result.text)
                self?.appState.setStatus(.idle)
            } catch {
                self?.appState.setStatus(.error("Test: \(error)"))
            }
        }
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

        let url = URL(string: current.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!
        let client = OllamaClient(baseURL: url)
        let identityCache = IdentityCache(file: AppPaths.identityCacheURL())
        let pipeline = CleanupPipeline(
            client: client,
            model: current.cleanupModel,
            identityCache: identityCache,
            mode: current.cleanupMode
        )
        let paster = PasterFactory.make(mode: current.pasteMode)
        self.testPipeline = pipeline
        self.testPaster = paster

        let orchestrator = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
            paster: paster,
            appState: appState,
            logger: history
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
