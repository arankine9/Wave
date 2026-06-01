// HotkeyController is the Fn-key state machine: tap, hold, double tap
// to lock, click to unlock. Every transition is timing-sensitive so
// the tests drive a TestClock to keep the press/release/timeout
// ordering deterministic.

import XCTest
@testable import WaveCore

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
        // Fn-down pre-arms immediately so audio capture has no startup lag.
        XCTAssertEqual(log.events, [.armRecording])

        // Hold past threshold → start recording (hold reason).
        clock.advance(by: 0.30)
        XCTAssertEqual(log.events, [.armRecording, .startRecording(reason: .hold)])
        XCTAssertTrue(c.isRecording)

        // Release → stop recording.
        c.handleReleased()
        XCTAssertEqual(log.events, [
            .armRecording,
            .startRecording(reason: .hold),
            .stopRecording
        ])
        XCTAssertFalse(c.isRecording)
    }

    func testQuickSingleTapArmsThenDisarms() {
        let (c, clock, log) = makeController()
        c.handlePressed()
        XCTAssertEqual(log.events, [.armRecording])
        clock.advance(by: 0.05)
        c.handleReleased()
        // During the double-tap window, the arm is still live (a second tap
        // could lock-on without losing audio).
        XCTAssertEqual(log.events, [.armRecording])
        clock.advance(by: 0.50)
        // Window expired without a second tap → tear down.
        XCTAssertEqual(log.events, [.armRecording, .disarmRecording])
        XCTAssertFalse(c.isRecording)
    }

    func testDoubleTapLocksOnRelease() {
        let (c, clock, log) = makeController()

        // First tap.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        // Second press inside double-tap window. The session armed by the
        // first press is reused — no second `.armRecording`.
        clock.advance(by: 0.10)
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()

        XCTAssertEqual(log.events, [.armRecording, .startRecording(reason: .locked)])
        XCTAssertTrue(c.isRecording)

        // Subsequent tap unlocks. The unlocking press does NOT re-arm.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        XCTAssertEqual(log.events, [
            .armRecording,
            .startRecording(reason: .locked),
            .stopRecording
        ])
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
        XCTAssertEqual(log.events, [.armRecording, .startRecording(reason: .locked)])

        // Release of second press does not stop locked recording.
        c.handleReleased()
        XCTAssertEqual(log.events, [.armRecording, .startRecording(reason: .locked)])
        XCTAssertTrue(c.isRecording)

        // Click to unlock.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        XCTAssertEqual(log.events, [
            .armRecording,
            .startRecording(reason: .locked),
            .stopRecording
        ])
    }

    func testSecondPressOutsideWindowIsTreatedAsNewSingleTap() {
        let (c, clock, log) = makeController()
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        // Wait past the double-tap window. First arm disarms.
        clock.advance(by: 0.40)
        XCTAssertEqual(log.events, [.armRecording, .disarmRecording])
        // Another quick tap by itself: arms and then disarms again.
        c.handlePressed()
        clock.advance(by: 0.05)
        c.handleReleased()
        clock.advance(by: 0.40)
        XCTAssertEqual(log.events, [
            .armRecording, .disarmRecording,
            .armRecording, .disarmRecording
        ])
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
