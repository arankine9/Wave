import XCTest
@testable import BeckCore

final class STTBackendFactoryTests: XCTestCase {
    func testVoxtralPrecheckReturnsFalseWhenEnvUnset() {
        // The harness shouldn't have BECK_VOXTRAL_PYTHON pointing at a
        // real interpreter; if it does, this test is a no-op signal that
        // the precheck would correctly say "yes, try Voxtral."
        let env = ProcessInfo.processInfo.environment
        if env["BECK_VOXTRAL_PYTHON"] == nil {
            XCTAssertFalse(STTBackendFactory.voxtralAvailable())
        }
    }

    func testFactoryReturnsWhisperByDefault() throws {
        guard STTBackendFactory.whisperCppAvailable() else {
            throw XCTSkip("whisper.cpp not installed; run `brew install whisper-cpp` and download a model to ~/.beck/models/")
        }
        let backend = try STTBackendFactory.make(for: .whisperCpp)
        XCTAssertTrue(backend is WhisperCppBackend)
    }

    func testFactoryFallsBackToWhisperWhenVoxtralUnavailable() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["BECK_VOXTRAL_PYTHON"] == nil else {
            throw XCTSkip("BECK_VOXTRAL_PYTHON is set; precheck would succeed")
        }
        guard STTBackendFactory.whisperCppAvailable() else {
            throw XCTSkip("whisper.cpp not installed for fallback target")
        }
        let backend = try STTBackendFactory.make(for: .voxtral)
        XCTAssertTrue(backend is WhisperCppBackend,
            "expected fallback to WhisperCppBackend when sidecar isn't available")
    }
}
