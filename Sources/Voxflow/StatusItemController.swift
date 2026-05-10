import AppKit
import VoxflowCore

@MainActor
final class StatusItemController {
    private let appState: AppState
    private let openSettings: () -> Void
    private let openHistory: () -> Void
    private let runTestDictation: () -> Void
    private var statusItem: NSStatusItem?
    private let statusMenuItem = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")

    init(
        appState: AppState,
        openSettings: @escaping () -> Void,
        openHistory: @escaping () -> Void,
        runTestDictation: @escaping () -> Void
    ) {
        self.appState = appState
        self.openSettings = openSettings
        self.openHistory = openHistory
        self.runTestDictation = runTestDictation
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Voxflow")
            symbol?.isTemplate = true
            button.image = symbol
            button.toolTip = "Voxflow"
        }
        item.menu = buildMenu()
        statusItem = item

        appState.onStatusChange = { [weak self] status in
            Task { @MainActor in
                self?.statusMenuItem.title = "Status: \(status.displayName)"
            }
        }
    }

    func uninstall() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Test Dictation (paste sample)", action: #selector(runTestAction), keyEquivalent: "t"))
        menu.addItem(NSMenuItem(title: "Open Settings…", action: #selector(openSettingsAction), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "Open History…", action: #selector(openHistoryAction), keyEquivalent: "h"))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Voxflow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
}
