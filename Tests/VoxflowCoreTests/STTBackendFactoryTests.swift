import XCTest
@testable import VoxflowCore

final class STTBackendFactoryTests: XCTestCase {
    func testVoxtralPrecheckReturnsFalseWhenEnvUnset() {
        // The harness shouldn't have VOXFLOW_VOXTRAL_PYTHON pointing at a
        // real interpreter; if it does, this test is a no-op signal that
        // the precheck would correctly say "yes, try Voxtral."
        let env = ProcessInfo.processInfo.environment
        if env["VOXFLOW_VOXTRAL_PYTHON"] == nil {
            XCTAssertFalse(STTBackendFactory.voxtralAvailable())
        }
    }

    func testFactoryReturnsAppleByDefault() throws {
        let backend = try STTBackendFactory.make(for: .apple)
        XCTAssertTrue(backend is AppleSpeechBackend)
    }

    func testFactoryFallsBackToAppleWhenVoxtralUnavailable() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["VOXFLOW_VOXTRAL_PYTHON"] == nil else {
            throw XCTSkip("VOXFLOW_VOXTRAL_PYTHON is set; precheck would succeed")
        }
        let backend = try STTBackendFactory.make(for: .voxtral)
        XCTAssertTrue(backend is AppleSpeechBackend,
            "expected fallback to AppleSpeechBackend when sidecar isn't available")
    }
}
