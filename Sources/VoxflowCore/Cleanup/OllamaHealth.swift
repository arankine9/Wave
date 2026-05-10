import Foundation

public struct OllamaHealth: Sendable, Equatable {
    public enum Server: Sendable, Equatable {
        case reachable
        case unreachable(String)
    }

    public let server: Server
    public let modelAvailable: Bool
    public let availableModels: [String]
    public let probedAt: Date

    public init(server: Server, modelAvailable: Bool, availableModels: [String], probedAt: Date) {
        self.server = server
        self.modelAvailable = modelAvailable
        self.availableModels = availableModels
        self.probedAt = probedAt
    }
}

public enum OllamaHealthProbe {
    /// Hits `/api/tags` and reports server reachability + whether the
    /// configured cleanup model is in the response.
    public static func check(
        baseURL: URL,
        wantedModel: String,
        session: URLSession = .shared,
        timeout: TimeInterval = 1.5
    ) async -> OllamaHealth {
        let url = baseURL.appendingPathComponent("api/tags")
        let request: URLRequest = {
            var r = URLRequest(url: url)
            r.timeoutInterval = timeout
            return r
        }()

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                return OllamaHealth(
                    server: .unreachable("HTTP \(http.statusCode)"),
                    modelAvailable: false, availableModels: [],
                    probedAt: Date()
                )
            }
            let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let models = (decoded?["models"] as? [[String: Any]]) ?? []
            let names = models.compactMap { $0["name"] as? String }
            return OllamaHealth(
                server: .reachable,
                modelAvailable: names.contains(wantedModel),
                availableModels: names,
                probedAt: Date()
            )
        } catch {
            return OllamaHealth(
                server: .unreachable(error.localizedDescription),
                modelAvailable: false, availableModels: [],
                probedAt: Date()
            )
        }
    }
}
