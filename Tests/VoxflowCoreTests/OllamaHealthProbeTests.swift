import XCTest
@testable import VoxflowCore

/// Stand up a tiny in-process URL protocol so we can exercise the probe
/// without a real Ollama daemon.
final class OllamaHealthProbeTests: XCTestCase {
    func testReachableWithModelPulled() async {
        StubURLProtocol.respond = .json(200, [
            "models": [
                ["name": "qwen2.5-coder:7b-instruct"],
                ["name": "llama3.2:3b"],
            ]
        ])
        let h = await OllamaHealthProbe.check(
            baseURL: URL(string: "http://stub")!,
            wantedModel: "qwen2.5-coder:7b-instruct",
            session: stubSession()
        )
        XCTAssertEqual(h.server, .reachable)
        XCTAssertTrue(h.modelAvailable)
        XCTAssertEqual(h.availableModels.count, 2)
    }

    func testReachableButModelMissing() async {
        StubURLProtocol.respond = .json(200, ["models": [["name": "llama3.2:3b"]]])
        let h = await OllamaHealthProbe.check(
            baseURL: URL(string: "http://stub")!,
            wantedModel: "qwen2.5-coder:7b-instruct",
            session: stubSession()
        )
        XCTAssertEqual(h.server, .reachable)
        XCTAssertFalse(h.modelAvailable)
        XCTAssertEqual(h.availableModels, ["llama3.2:3b"])
    }

    func testUnreachable() async {
        StubURLProtocol.respond = .error(NSError(domain: "test", code: -1))
        let h = await OllamaHealthProbe.check(
            baseURL: URL(string: "http://stub")!,
            wantedModel: "any",
            session: stubSession()
        )
        if case .reachable = h.server {
            XCTFail("expected unreachable, got \(h.server)")
        }
        XCTAssertFalse(h.modelAvailable)
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: cfg)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response { case json(Int, [String: Any]); case error(Error) }
    nonisolated(unsafe) static var respond: Response = .error(NSError(domain: "init", code: 0))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        switch StubURLProtocol.respond {
        case .json(let code, let body):
            let data = try! JSONSerialization.data(withJSONObject: body)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .error(let err):
            client?.urlProtocol(self, didFailWithError: err)
        }
    }

    override func stopLoading() {}
}
