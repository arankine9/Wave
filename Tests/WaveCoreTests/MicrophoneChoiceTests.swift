// MicrophoneChoice gets persisted to UserDefaults as a raw string, so
// rawValue round-trips have to be lossless across every case and
// unknown strings have to reject cleanly without crashing.

import XCTest
@testable import WaveCore

final class MicrophoneChoiceTests: XCTestCase {
    func testRawValueRoundTrip() {
        let cases: [MicrophoneChoice] = [
            .builtIn,
            .systemDefault,
            .specific(uid: "BuiltInMicrophoneDevice"),
            .specific(uid: "AppleHFP:0000-1111-2222"),
        ]
        for choice in cases {
            let raw = choice.rawValue
            XCTAssertEqual(MicrophoneChoice(rawValue: raw), choice, "round-trip failed for \(choice)")
        }
    }

    func testUnknownRawValueReturnsNil() {
        XCTAssertNil(MicrophoneChoice(rawValue: "nonsense"))
        XCTAssertNil(MicrophoneChoice(rawValue: ""))
    }

    func testSpecificPrefixRequired() {
        // Trailing empty UID is degenerate but legal — survives round trip.
        XCTAssertEqual(MicrophoneChoice(rawValue: "uid:"), .specific(uid: ""))
    }

    func testDefaultPreferencesIsBuiltIn() {
        let prefs = Preferences()
        XCTAssertEqual(prefs.microphoneChoice, .builtIn)
    }
}
