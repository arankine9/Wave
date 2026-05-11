import XCTest
@testable import BeckCore

final class AppStateTests: XCTestCase {
    func testInitialStatusIsIdle() {
        let state = AppState()
        XCTAssertEqual(state.status, .idle)
    }

    func testStatusTransitionFiresCallback() {
        let state = AppState()
        let exp = expectation(description: "status callback")
        state.onStatusChange = { status in
            if status == .recording { exp.fulfill() }
        }
        state.setStatus(.recording)
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(state.status, .recording)
    }

    func testDisplayNames() {
        XCTAssertEqual(DictationStatus.idle.displayName, "Idle")
        XCTAssertEqual(DictationStatus.recording.displayName, "Recording")
        XCTAssertEqual(DictationStatus.error("oops").displayName, "Error: oops")
    }

    func testVersionIsSet() {
        XCTAssertFalse(BeckVersion.current.isEmpty)
    }
}
