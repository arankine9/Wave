import Foundation

public enum DictationStatus: Sendable, Equatable {
    case idle
    case recording
    case transcribing
    case cleaning
    case pasting
    case error(String)

    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .recording: return "Recording"
        case .transcribing: return "Transcribing"
        case .cleaning: return "Cleaning"
        case .pasting: return "Pasting"
        case .error(let message): return "Error: \(message)"
        }
    }
}

public final class AppState: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.voxflow.appstate")
    private var _status: DictationStatus = .idle
    public var onStatusChange: (@Sendable (DictationStatus) -> Void)?

    public init() {}

    public var status: DictationStatus {
        queue.sync { _status }
    }

    public func setStatus(_ next: DictationStatus) {
        queue.sync {
            _status = next
        }
        onStatusChange?(next)
    }
}
