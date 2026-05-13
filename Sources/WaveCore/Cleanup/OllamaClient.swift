import Foundation

public final class OllamaClient: CleanupClient, @unchecked Sendable {
    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public convenience init(baseURLString: String) {
        let url = URL(string: baseURLString) ?? URL(string: "http://127.0.0.1:11434")!
        self.init(baseURL: url)
    }

    public func stream(
        systemPrompt: String,
        userText: String,
        model: String
    ) -> AsyncThrowingStream<String, Error> {
        let endpoint = baseURL.appendingPathComponent("api/chat")
        let body: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userText],
            ],
            "options": [
                // Tight budget; avoids burning tokens on long generations.
                "num_predict": 400,
                "temperature": 0.2,
            ],
        ]

        let request: URLRequest = {
            var r = URLRequest(url: endpoint)
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return r
        }()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        if http.statusCode == 404 {
                            throw CleanupError.modelMissing(model)
                        }
                        throw CleanupError.http(http.statusCode)
                    }
                    for try await line in bytes.lines {
                        if line.isEmpty { continue }
                        guard let data = line.data(using: .utf8) else { continue }
                        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                            continuation.finish(throwing: CleanupError.decode(line))
                            return
                        }
                        if let message = obj["message"] as? [String: Any],
                           let content = message["content"] as? String,
                           !content.isEmpty {
                            continuation.yield(content)
                        }
                        if let done = obj["done"] as? Bool, done {
                            continuation.finish()
                            return
                        }
                    }
                    continuation.finish()
                } catch let err as CleanupError {
                    continuation.finish(throwing: err)
                } catch {
                    continuation.finish(throwing: CleanupError.transport(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
