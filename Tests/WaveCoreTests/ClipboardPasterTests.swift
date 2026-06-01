// Paster has to put the dictated text on the clipboard, fire Cmd+V,
// then restore the user's original clipboard contents. Easy to get
// wrong around the restore timing, especially when the user copies
// something during the restore window or the paste itself fails before
// the restore is scheduled.

#if canImport(AppKit)
import AppKit
import XCTest
@testable import WaveCore

final class ClipboardPasterTests: XCTestCase {
    func testRestoresOriginalClipboardAfterPaste() throws {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let scheduler = CapturingScheduler()
        let paster = ClipboardPaster(
            pasteboard: pb,
            restoreDelay: 0,
            postPasteHotkey: {},
            scheduleRestore: scheduler.schedule
        )

        try paster.paste("DICTATED")

        // Between paste and restore, the dictated text is on the clipboard
        // so the frontmost app's Cmd+V picks it up.
        XCTAssertEqual(pb.string(forType: .string), "DICTATED")

        scheduler.fire()

        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testRestoresMultipleTypesOnOriginalItem() throws {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString("ORIGINAL", forType: .string)
        item.setString("<b>ORIGINAL</b>", forType: .html)
        pb.writeObjects([item])

        let scheduler = CapturingScheduler()
        let paster = ClipboardPaster(
            pasteboard: pb,
            restoreDelay: 0,
            postPasteHotkey: {},
            scheduleRestore: scheduler.schedule
        )

        try paster.paste("DICTATED")
        scheduler.fire()

        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
        XCTAssertEqual(pb.string(forType: .html), "<b>ORIGINAL</b>")
    }

    func testDoesNotRestoreIfClipboardChangedAfterPaste() throws {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let scheduler = CapturingScheduler()
        let paster = ClipboardPaster(
            pasteboard: pb,
            restoreDelay: 0,
            postPasteHotkey: {},
            scheduleRestore: scheduler.schedule
        )

        try paster.paste("DICTATED")

        // Simulate the user (or another tool) copying something during the
        // restore window. We should leave it alone.
        pb.clearContents()
        pb.setString("USER_COPY", forType: .string)

        scheduler.fire()

        XCTAssertEqual(pb.string(forType: .string), "USER_COPY")
    }

    func testRestoresImmediatelyWhenHotkeyPostFails() {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString("ORIGINAL", forType: .string)

        let scheduler = CapturingScheduler()
        let paster = ClipboardPaster(
            pasteboard: pb,
            restoreDelay: 0,
            postPasteHotkey: { throw PasterError.missingAccessibility },
            scheduleRestore: scheduler.schedule
        )

        XCTAssertThrowsError(try paster.paste("DICTATED"))
        XCTAssertFalse(scheduler.didSchedule, "no deferred restore should be scheduled when paste failed")
        XCTAssertEqual(pb.string(forType: .string), "ORIGINAL")
    }

    func testEmptyClipboardSkipsRestoreSchedule() throws {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()

        let scheduler = CapturingScheduler()
        let paster = ClipboardPaster(
            pasteboard: pb,
            restoreDelay: 0,
            postPasteHotkey: {},
            scheduleRestore: scheduler.schedule
        )

        try paster.paste("DICTATED")

        XCTAssertFalse(scheduler.didSchedule)
        XCTAssertEqual(pb.string(forType: .string), "DICTATED")
    }
}

/// Captures the restore block instead of running it on a timer so the test
/// can fire it deterministically.
private final class CapturingScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: (() -> Void)?

    var didSchedule: Bool { lock.withLock { captured != nil } }

    lazy var schedule: @Sendable (TimeInterval, @escaping @Sendable () -> Void) -> Void = { [weak self] _, block in
        self?.lock.withLock { self?.captured = block }
    }

    func fire() {
        let block = lock.withLock { () -> (() -> Void)? in
            let b = captured
            captured = nil
            return b
        }
        block?()
    }
}
#endif
