import Foundation

public enum STTBackendFactory {
    /// Returns the STT backend matching the user's preference. When
    /// `.voxtral` is selected we attempt to spawn the Python sidecar; if
    /// `VOXFLOW_VOXTRAL_PYTHON` isn't set or the sidecar isn't reachable we
    /// surface the reason and fall back to Apple Speech so the app stays
    /// functional.
    public static func make(for kind: STTBackendKind) throws -> STTBackend {
        switch kind {
        case .apple:
            return try AppleSpeechBackend()
        case .voxtral:
            if voxtralAvailable() {
                return VoxtralBackend()
            }
            // Fall back transparently. The user-visible signal is in
            // VoxtralBackend's `startSession` — the launch path itself
            // shouldn't fail just because Python isn't installed.
            return try AppleSpeechBackend()
        }
    }

    /// Best-effort precheck: only true when both env-var and script exist.
    /// We never run Python here because that would block app launch on the
    /// model load.
    public static func voxtralAvailable() -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard let python = env["VOXFLOW_VOXTRAL_PYTHON"], !python.isEmpty else { return false }
        guard FileManager.default.isExecutableFile(atPath: python) else { return false }
        let script = VoxtralBackend.Config().sidecarScriptPath
        return FileManager.default.fileExists(atPath: script)
    }
}
