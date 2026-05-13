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
    private let queue = DispatchQueue(label: "com.beck.appstate")
    private var _status: DictationStatus = .idle
    private var _partial: String = ""
    public var onStatusChange: (@Sendable (DictationStatus) -> Void)?
    public var onPartialChange: (@Sendable (String) -> Void)?
    /// Fires from the audio thread with the latest mic RMS level (0…~0.3 for
    /// normal speech). Consumers must hop to their own queue/actor before
    /// touching UI state.
    public var onAudioLevel: (@Sendable (Float) -> Void)?

    public init() {}

    public var status: DictationStatus {
        queue.sync { _status }
    }

    public func setStatus(_ next: DictationStatus) {
        queue.sync {
            _status = next
        }
        onStatusChange?(next)

        // Errors are sticky in the menu bar otherwise; auto-fade to idle so
        // the next dictation cycle starts clean. The 3s window is enough for
        // the user to glance at the menu bar but short enough not to confuse.
        if case .error = next {
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                if case .error = self.status {
                    self.queue.sync { self._status = .idle }
                    self.onStatusChange?(.idle)
                }
            }
        }
    }

    public var partial: String {
        queue.sync { _partial }
    }

    public func setPartial(_ text: String) {
        queue.sync { _partial = text }
        onPartialChange?(text)
    }

    public func setAudioLevel(_ level: Float) {
        onAudioLevel?(level)
    }
}
