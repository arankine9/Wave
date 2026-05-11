import XCTest
@testable import VoxflowCore

/// Real end-to-end whisper.cpp transcription. Synthesizes a known phrase via
/// macOS `say` (no Apple Speech Recognition framework — `say` is text-to-speech,
/// the inverse direction, and requires no permission), then runs the binary
/// the production WhisperCppSession would invoke and asserts the transcript.
///
/// Skipped automatically when whisper.cpp isn't installed so CI without the
/// homebrew package still passes.
final class WhisperCppBackendTests: XCTestCase {
    func testTranscribesSynthesizedSpeech() async throws {
        guard WhisperCppBackend.isAvailable() else {
            throw XCTSkip("whisper.cpp not installed; install with `brew install whisper-cpp` and download a model to ~/.voxflow/models/ggml-base.en.bin")
        }

        let phrase = "Hello world this is a Voxflow test"
        let wavURL = try synthesizeWav(text: phrase)
        defer { try? FileManager.default.removeItem(at: wavURL) }

        let transcript = try await WhisperCppBackend.transcribe(wavPath: wavURL.path)
        let normalized = transcript.lowercased()
        XCTAssertTrue(
            normalized.contains("hello") && normalized.contains("voxflow"),
            "expected transcript to mention 'hello' and 'voxflow'; got: \(transcript)"
        )
    }

    /// Use `say` (TTS) and `afconvert` to produce a 16 kHz mono int16 WAV the
    /// model expects. Both binaries ship with macOS; no third-party deps.
    private func synthesizeWav(text: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
        let aiff = tmp.appendingPathComponent("voxflow-test-\(UUID().uuidString).aiff")
        let wav = tmp.appendingPathComponent("voxflow-test-\(UUID().uuidString).wav")
        try run("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])
        try? FileManager.default.removeItem(at: aiff)
        return wav
    }

    private func run(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw NSError(
                domain: "WhisperCppBackendTests",
                code: Int(p.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(path) exit=\(p.terminationStatus)"]
            )
        }
    }
}
