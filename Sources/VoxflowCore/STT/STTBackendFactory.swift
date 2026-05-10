import Foundation

public enum STTBackendFactory {
    /// Returns the STT backend matching the user's preference. Voxtral is
    /// reserved for a future on-device deployment; for now it falls back to
    /// the Apple Speech backend so the app stays functional.
    public static func make(for kind: STTBackendKind) throws -> STTBackend {
        switch kind {
        case .apple, .voxtral:
            return try AppleSpeechBackend()
        }
    }
}
