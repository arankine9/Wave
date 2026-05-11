import Foundation
import ServiceManagement

/// Wraps SMAppService.mainApp so the Settings UI can flip launch-at-login
/// on and off without dealing with the framework's funky enum surface.
///
/// On macOS 13+ SMAppService.mainApp is the modern, sandbox-friendly way to
/// register an app as a Login Item. The app appears under System Settings →
/// General → Login Items, and the user can revoke it there too.
@MainActor
enum LaunchAtLogin {
    enum Status: Equatable {
        case enabled
        case disabled
        case requiresApproval
        case notSupported
    }

    static var current: Status {
        guard #available(macOS 13.0, *) else { return .notSupported }
        switch SMAppService.mainApp.status {
        case .enabled:           return .enabled
        case .notRegistered:     return .disabled
        case .requiresApproval:  return .requiresApproval
        case .notFound:          return .disabled
        @unknown default:        return .disabled
        }
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Result<Status, Error> {
        guard #available(macOS 13.0, *) else { return .success(.notSupported) }
        let svc = SMAppService.mainApp
        do {
            if enabled {
                if svc.status != .enabled { try svc.register() }
            } else {
                if svc.status == .enabled { try svc.unregister() }
            }
            return .success(current)
        } catch {
            return .failure(error)
        }
    }
}
