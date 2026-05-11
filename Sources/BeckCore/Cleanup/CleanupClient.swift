import Foundation

public enum CleanupError: Error, Equatable {
    case http(Int)
    case decode(String)
    case transport(String)
    case modelMissing(String)
}

/// A streaming chat client that the pipeline talks to. Production impl is
/// `OllamaClient`; tests inject a stub so the pipeline can be exercised
/// without a running server.
public protocol CleanupClient: Sendable {
    func stream(
        systemPrompt: String,
        userText: String,
        model: String
    ) -> AsyncThrowingStream<String, Error>
}
