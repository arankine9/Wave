import AppKit
import Foundation

enum PermissionPrompt: String, CaseIterable, Sendable {
    case accessibility = "Privacy_Accessibility"
    case microphone = "Privacy_Microphone"

    var title: String {
        switch self {
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        }
    }

    var settingsURL: URL {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)") else {
            preconditionFailure("Invalid System Settings URL for \(rawValue)")
        }
        return url
    }
}

struct PermissionPromptHostApp: Sendable {
    let displayName: String
    let bundleURL: URL
    let icon: NSImage

    static func current(bundle: Bundle = .main) -> PermissionPromptHostApp {
        let displayName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String
            ?? bundle.bundleURL.deletingPathExtension().lastPathComponent
        let icon = NSWorkspace.shared.icon(forFile: bundle.bundleURL.path)
        icon.size = NSSize(width: 48, height: 48)
        return PermissionPromptHostApp(displayName: displayName, bundleURL: bundle.bundleURL, icon: icon)
    }
}
