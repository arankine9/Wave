import AppKit
import VoxflowCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private let appState = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(appState: appState)
        statusController?.install()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.uninstall()
    }
}
