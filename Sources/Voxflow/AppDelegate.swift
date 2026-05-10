import AppKit
import VoxflowCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var settingsController: SettingsWindowController?
    private let appState = AppState()
    private let prefs = PreferencesStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = SettingsWindowController(prefs: prefs)
        settingsController = settings
        statusController = StatusItemController(
            appState: appState,
            openSettings: { [weak settings] in settings?.show() }
        )
        statusController?.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.uninstall()
    }
}
