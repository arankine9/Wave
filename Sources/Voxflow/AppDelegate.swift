import AppKit
import VoxflowCore

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

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        let onboarding = OnboardingWindowController()
        onboardingController = onboarding
        onboarding.showIfPermissionsMissing()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor?.stop()
        statusController?.uninstall()
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
        let backend: STTBackend
        do {
            backend = try STTBackendFactory.make(for: current.sttBackend)
        } catch {
            appState.setStatus(.error("STT init: \(error)"))
            return
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
            Task { await orchestrator.handle(event) }
        }
        hotkeyController = controller

        let monitor = FnKeyMonitor()
        monitor.onPressed = { [weak controller] in
            controller?.handlePressed()
        }
        monitor.onReleased = { [weak controller] in
            controller?.handleReleased()
        }

        do {
            try monitor.start()
            fnMonitor = monitor
        } catch FnKeyMonitorError.tapCreateFailed {
            appState.setStatus(.error("Grant Input Monitoring in Privacy & Security"))
            FnKeyMonitor.requestInputMonitoringPermission()
        } catch {
            appState.setStatus(.error("Fn monitor: \(error)"))
        }
    }
}
