import Foundation

public enum PasteMode: String, Sendable, CaseIterable, Identifiable {
    case paste
    case type

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .paste: return "Paste (Cmd+V)"
        case .type:  return "Type each character"
        }
    }
}

/// User's microphone selection. Default is `.builtIn` — Wave pins the Mac's
/// built-in mic regardless of what macOS picks as the system default, because
/// Bluetooth/HFP inputs (AirPods, etc.) are heavily compressed and hurt STT
/// quality. Users who want plug-and-play behavior can pick `.systemDefault`,
/// or pin a specific device by UID.
public enum MicrophoneChoice: Sendable, Equatable, Hashable {
    case builtIn
    case systemDefault
    case specific(uid: String)
}

extension MicrophoneChoice: RawRepresentable {
    public var rawValue: String {
        switch self {
        case .builtIn:        return "builtIn"
        case .systemDefault:  return "systemDefault"
        case .specific(let u): return "uid:" + u
        }
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "builtIn":       self = .builtIn
        case "systemDefault": self = .systemDefault
        default:
            guard rawValue.hasPrefix("uid:") else { return nil }
            self = .specific(uid: String(rawValue.dropFirst(4)))
        }
    }
}

public struct Preferences: Sendable, Equatable {
    public var pasteMode: PasteMode
    public var holdThresholdMs: Int
    public var doubleTapWindowMs: Int
    public var microphoneChoice: MicrophoneChoice
    public var muteAudioWhileRecording: Bool

    public init(
        pasteMode: PasteMode = .paste,
        holdThresholdMs: Int = 250,
        doubleTapWindowMs: Int = 280,
        microphoneChoice: MicrophoneChoice = .builtIn,
        muteAudioWhileRecording: Bool = true
    ) {
        self.pasteMode = pasteMode
        self.holdThresholdMs = holdThresholdMs
        self.doubleTapWindowMs = doubleTapWindowMs
        self.microphoneChoice = microphoneChoice
        self.muteAudioWhileRecording = muteAudioWhileRecording
    }

    public static func loadFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Preferences {
        var p = Preferences()
        if let raw = env["WAVE_PASTE_MODE"], let v = PasteMode(rawValue: raw) {
            p.pasteMode = v
        }
        return p
    }
}

public final class PreferencesStore: @unchecked Sendable {
    // MARK: - Persistence
    // Most prefs are in-memory only today (loaded from env vars at startup);
    // a small set persists via UserDefaults so user choices survive restarts.
    private static let micChoiceKey = "WaveMicrophoneChoice"
    private static let muteAudioKey = "WaveMuteAudioWhileRecording"

    private let queue = DispatchQueue(label: "com.wave.prefs")
    private var _value: Preferences
    public var onChange: (@Sendable (Preferences) -> Void)?

    public init(initial: Preferences = .loadFromEnvironment()) {
        var seeded = initial
        if let raw = UserDefaults.standard.string(forKey: Self.micChoiceKey),
           let choice = MicrophoneChoice(rawValue: raw) {
            seeded.microphoneChoice = choice
        }
        if UserDefaults.standard.object(forKey: Self.muteAudioKey) != nil {
            seeded.muteAudioWhileRecording = UserDefaults.standard.bool(forKey: Self.muteAudioKey)
        }
        self._value = seeded
    }

    public var value: Preferences {
        queue.sync { _value }
    }

    public func update(_ mutate: (inout Preferences) -> Void) {
        let next: Preferences = queue.sync {
            mutate(&_value)
            return _value
        }
        // Persist the mic choice — default value clears the key so a future
        // default change is picked up automatically rather than pinned.
        if next.microphoneChoice == .builtIn {
            UserDefaults.standard.removeObject(forKey: Self.micChoiceKey)
        } else {
            UserDefaults.standard.set(next.microphoneChoice.rawValue, forKey: Self.micChoiceKey)
        }
        UserDefaults.standard.set(next.muteAudioWhileRecording, forKey: Self.muteAudioKey)
        onChange?(next)
    }
}
