#if canImport(AppKit)
import AppKit
import ApplicationServices
import AVFoundation
import Foundation

public enum PermissionGrant: String, Sendable {
    case granted
    case denied
    case undetermined
    case unknown
}

public struct PermissionsSnapshot: Sendable, Equatable {
    public let microphone: PermissionGrant
    public let accessibility: PermissionGrant
}

public enum PermissionsProbe {
    public static func current() -> PermissionsSnapshot {
        return PermissionsSnapshot(
            microphone: microphoneStatus(),
            accessibility: accessibilityStatus()
        )
    }

    public static func microphoneStatus() -> PermissionGrant {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .unknown
        }
    }

    public static func accessibilityStatus() -> PermissionGrant {
        return AXIsProcessTrusted() ? .granted : .denied
    }

    public static func requestMicrophone() async -> PermissionGrant {
        await withCheckedContinuation { c in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                c.resume(returning: granted ? .granted : .denied)
            }
        }
    }

    public static func openSystemSettings(_ pane: SettingsPane) {
        let url = URL(string: pane.urlString)!
        NSWorkspace.shared.open(url)
    }

    public enum SettingsPane: String {
        case microphone = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case accessibility = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"

        var urlString: String { rawValue }
    }
}
#endif
