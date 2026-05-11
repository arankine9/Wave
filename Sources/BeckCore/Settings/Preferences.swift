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
    case whisperCpp = "whisper-cpp"
    case voxtral

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .whisperCpp: return "Whisper.cpp (local, default)"
        case .voxtral:    return "Voxtral local (opt-in, heavier)"
        }
    }
}

public enum CleanupMode: String, Sendable, CaseIterable, Identifiable {
    case auto       // try LLM, fall back to heuristic, fall back to raw
    case heuristic  // skip the LLM entirely; always use HeuristicCleanup
    case off        // paste raw STT output

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .auto:      return "Auto (LLM, falls back to heuristic)"
        case .heuristic: return "Heuristic only (no LLM)"
        case .off:       return "Off (paste raw transcript)"
        }
    }
}

public struct Preferences: Sendable, Equatable {
    public var sttBackend: STTBackendKind
    public var cleanupModel: String
    public var ollamaURL: String
    public var pasteMode: PasteMode
    public var cleanupMode: CleanupMode
    public var holdThresholdMs: Int
    public var doubleTapWindowMs: Int

    public init(
        sttBackend: STTBackendKind = .whisperCpp,
        cleanupModel: String = "qwen2.5-coder:7b-instruct",
        ollamaURL: String = "http://127.0.0.1:11434",
        pasteMode: PasteMode = .paste,
        cleanupMode: CleanupMode = .auto,
        holdThresholdMs: Int = 250,
        doubleTapWindowMs: Int = 280
    ) {
        self.sttBackend = sttBackend
        self.cleanupModel = cleanupModel
        self.ollamaURL = ollamaURL
        self.pasteMode = pasteMode
        self.cleanupMode = cleanupMode
        self.holdThresholdMs = holdThresholdMs
        self.doubleTapWindowMs = doubleTapWindowMs
    }

    public static func loadFromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> Preferences {
        var p = Preferences()
        if let raw = env["BECK_STT_BACKEND"], let v = STTBackendKind(rawValue: raw) {
            p.sttBackend = v
        }
        if let raw = env["BECK_CLEANUP_MODEL"], !raw.isEmpty {
            p.cleanupModel = raw
        }
        if let raw = env["BECK_OLLAMA_URL"], !raw.isEmpty {
            p.ollamaURL = raw
        }
        if let raw = env["BECK_PASTE_MODE"], let v = PasteMode(rawValue: raw) {
            p.pasteMode = v
        }
        if let raw = env["BECK_CLEANUP_MODE"], let v = CleanupMode(rawValue: raw) {
            p.cleanupMode = v
        }
        return p
    }
}

public final class PreferencesStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.beck.prefs")
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
