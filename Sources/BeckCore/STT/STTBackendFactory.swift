import Foundation

public enum STTBackendFactory {
    /// Returns the STT backend matching the user's preference. Both backends
    /// run 100% locally and neither requires Apple's Speech Recognition
    /// entitlement. `whisperCpp` is the default; `voxtral` is opt-in for users
    /// who installed the Python sidecar (heavier model, more accurate).
    public static func make(for kind: STTBackendKind) throws -> STTBackend {
        switch kind {
        case .whisperCpp:
            return try WhisperCppBackend()
        case .voxtral:
            if voxtralAvailable() {
                return VoxtralBackend()
            }
            // Fall back to whisper.cpp (the default local backend) so the app
            // still works if the Voxtral sidecar isn't installed.
            return try WhisperCppBackend()
        }
    }

    /// Best-effort precheck: only true when env-var and script both exist.
    /// We never run Python here because that would block app launch on the
    /// model load.
    public static func voxtralAvailable() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let python = env["BECK_VOXTRAL_PYTHON"], !python.isEmpty else { return false }
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let script = VoxtralBackend.Config().sidecarScriptPath
        return FileManager.default.fileExists(atPath: script)
    }

    /// Whether the default whisper.cpp backend can be constructed (binary +
    /// model both present). Used by Diagnostics and Settings to surface a
    /// readable installer hint instead of just throwing at session start.
    public static func whisperCppAvailable() -> Bool {
        return WhisperCppBackend.isAvailable()
    }
}
