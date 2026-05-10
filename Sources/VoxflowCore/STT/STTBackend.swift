import Foundation

public enum STTError: Error, Equatable {
    case backendUnavailable(String)
    case notAuthorized
    case engineError(String)
    case sessionAlreadyActive
    case sessionNotActive
}

public struct STTPartial: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }
}

public protocol STTBackend: AnyObject {
    /// Begin a new dictation session. The returned session captures audio
    /// internally (so the backend can pick the format it needs).
    func startSession() async throws -> STTSession
}

public protocol STTSession: AnyObject {
    /// Async stream of partial transcripts. Closes on finalize/cancel.
    var partials: AsyncStream<STTPartial> { get }

    /// Stop capturing audio and return the final transcript.
    func finalize() async throws -> String

    /// Discard the session without returning a transcript.
    func cancel()
}
