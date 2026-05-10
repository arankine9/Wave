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

public enum STTBackendKind: String, Sendable, CaseIterable, Identifiable {
    case apple
    case voxtral

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .apple:   return "Apple Speech (on-device)"
        case .voxtral: return "Voxtral local (future)"
        }
    }
}

public struct Preferences: Sendable, Equatable {
    public var sttBackend: STTBackendKind
    public var cleanupModel: String
    public var ollamaURL: String
    public var pasteMode: PasteMode
    public var holdThresholdMs: Int
    public var doubleTapWindowMs: Int

    public init(
        sttBackend: STTBackendKind = .apple,
        cleanupModel: String = "qwen2.5-coder:7b-instruct",
        ollamaURL: String = "http://127.0.0.1:11434",
        pasteMode: PasteMode = .paste,
        holdThresholdMs: Int = 250,
        doubleTapWindowMs: Int = 280
    ) {
        self.sttBackend = sttBackend
        self.cleanupModel = cleanupModel
        self.ollamaURL = ollamaURL
        self.pasteMode = pasteMode
        self.holdThresholdMs = holdThresholdMs
        self.doubleTapWindowMs = doubleTapWindowMs
    }

    public static func loadFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Preferences {
        var p = Preferences()
        if let raw = env["VOXFLOW_STT_BACKEND"], let v = STTBackendKind(rawValue: raw) {
            p.sttBackend = v
        }
        if let raw = env["VOXFLOW_CLEANUP_MODEL"], !raw.isEmpty {
            p.cleanupModel = raw
        }
        if let raw = env["VOXFLOW_OLLAMA_URL"], !raw.isEmpty {
            p.ollamaURL = raw
        }
        if let raw = env["VOXFLOW_PASTE_MODE"], let v = PasteMode(rawValue: raw) {
            p.pasteMode = v
        }
        return p
    }
}

public final class PreferencesStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.voxflow.prefs")
    private var _value: Preferences
    public var onChange: (@Sendable (Preferences) -> Void)?

    public init(initial: Preferences = .loadFromEnvironment()) {
        self._value = initial
    }

    public var value: Preferences {
        queue.sync { _value }
    }

    public func update(_ mutate: (inout Preferences) -> Void) {
        let next: Preferences = queue.sync {
            mutate(&_value)
            return _value
        }
        onChange?(next)
    }
}
