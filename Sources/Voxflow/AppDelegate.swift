import AppKit
import VoxflowCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private let appState = AppState()
    private let prefs = PreferencesStore()
    private var fnMonitor: FnKeyMonitor?
    private var hotkeyController: HotkeyController?
    private var orchestrator: DictationOrchestrator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        SystemPrompt.assertWithinBudget()

        let settings = SettingsWindowController(prefs: prefs)
        settingsController = settings
        statusController = StatusItemController(
            appState: appState,
            openSettings: { [weak settings] in settings?.show() }
        )
        statusController?.install()

        installDictationPipeline()
    }

    func applicationWillTerminate(_ notification: Notification) {
        fnMonitor?.stop()
        statusController?.uninstall()
    }

    private func installDictationPipeline() {
        let current = prefs.value
        let backend: STTBackend
        do {
            switch current.sttBackend {
            case .apple, .voxtral:
                backend = try AppleSpeechBackend()
            }
        } catch {
            appState.setStatus(.error("STT init: \(error)"))
            return
        }

        let url = URL(string: current.ollamaURL) ?? URL(string: "http://127.0.0.1:11434")!
        let client = OllamaClient(baseURL: url)
        let pipeline = CleanupPipeline(client: client, model: current.cleanupModel)
        let paster = PasterFactory.make(mode: current.pasteMode)

        let orchestrator = DictationOrchestrator(
            backend: backend,
            cleanup: pipeline,
            paster: paster,
            appState: appState
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
