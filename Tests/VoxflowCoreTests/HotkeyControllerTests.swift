import XCTest
@testable import VoxflowCore

final class HotkeyControllerTests: XCTestCase {
    private func makeController() -> (HotkeyController, TestClock, EventLog) {
        let clock = TestClock()
        let controller = HotkeyController(clock: clock, holdThresholdMs: 250, doubleTapWindowMs: 280)
        let log = EventLog()
        controller.onEvent = { event in log.append(event) }
        return (controller, clock, log)
    }

    func testPressAndHoldStartsAndStopsOnRelease() {
        let (c, clock, log) = makeController()

        c.handlePressed()
        XCTAssertEqual(log.events, [])

        // Hold past threshold → start recording (hold reason).
        clock.advance(by: 0.30)
        XCTAssertEqual(log.events, [.startRecording(reason: .hold)])
        XCTAssertTrue(c.isRecording)

        // Release → stop recording.
        c.handleReleased()
        XCTAssertEqual(log.events, [.startRecording(reason: .hold), .stopRecording])
        XCTAssertFalse(c.isRecording)
    }

    func testQuickSingleTapDoesNothing() {
        let (c, clock, log) = makeController()
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        // Wait past the double-tap window.
        clock.advance(by: 0.50)
        XCTAssertEqual(log.events, [])
        XCTAssertFalse(c.isRecording)
    }

    func testDoubleTapLocksOnRelease() {
        let (c, clock, log) = makeController()

        // First tap.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        // Second press inside double-tap window.
        clock.advance(by: 0.10)
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()

        XCTAssertEqual(log.events, [.startRecording(reason: .locked)])
        XCTAssertTrue(c.isRecording)

        // Subsequent tap unlocks.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        XCTAssertEqual(log.events, [.startRecording(reason: .locked), .stopRecording])
        XCTAssertFalse(c.isRecording)
    }

    func testSecondPressHeldPastThresholdAlsoLocks() {
        let (c, clock, log) = makeController()

        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        clock.advance(by: 0.10)
        c.handlePressed()
        // Second press held past hold threshold: enters locked-on while still held.
        clock.advance(by: 0.30)
        XCTAssertEqual(log.events, [.startRecording(reason: .locked)])

        // Release of second press does not stop locked recording.
        c.handleReleased()
        XCTAssertEqual(log.events, [.startRecording(reason: .locked)])
        XCTAssertTrue(c.isRecording)

        // Click to unlock.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        XCTAssertEqual(log.events, [.startRecording(reason: .locked), .stopRecording])
    }

    func testSecondPressOutsideWindowIsTreatedAsNewSingleTap() {
        let (c, clock, log) = makeController()
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        // Wait past the double-tap window.
        clock.advance(by: 0.40)
        // Another quick tap by itself: no-op.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        clock.advance(by: 0.40)
        XCTAssertEqual(log.events, [])
    }

    func testSpuriousReleaseInIdleIsIgnored() {
        let (c, _, log) = makeController()
        c.handleReleased()
        XCTAssertEqual(log.events, [])
        XCTAssertFalse(c.isRecording)
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [HotkeyEvent] = []
    var events: [HotkeyEvent] { lock.withLock { _events } }
    func append(_ event: HotkeyEvent) { lock.withLock { _events.append(event) } }
}
