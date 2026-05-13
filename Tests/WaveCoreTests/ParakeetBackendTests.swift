import XCTest
import AVFoundation
@testable import WaveCore
@testable import FluidAudio

/// End-to-end Parakeet integration test. Synthesizes a known phrase via the
/// macOS `say` binary (text-to-speech — the inverse direction, requires no
/// permission), decodes it to a 16 kHz mono Float buffer, and runs it through
/// the same FluidAudio `AsrManager.transcribe(_:decoderState:)` call path
/// `ParakeetSession` uses. Asserts the model recognises the phrase.
///
/// Triggers a real model download (a few hundred MB) on first run if the
/// FluidAudio cache is empty, so it's gated behind the `WAVE_RUN_PARAKEET_TEST`
/// env var to keep the default `swift test` cycle fast and offline.
final class ParakeetBackendTests: XCTestCase {
    func testParakeetTranscribesSynthesizedSpeech() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["WAVE_RUN_PARAKEET_TEST"] == "1" else {
            throw XCTSkip("set WAVE_RUN_PARAKEET_TEST=1 to run the Parakeet integration test (downloads ~hundreds of MB on first run)")
        }

        let phrase = "Hello world this is a Wave test"
        let samples = try synthesize16kFloat(text: phrase)
        XCTAssertGreaterThan(samples.count, 16000, "synthesized clip should be at least one second")

        let manager = AsrManager(config: .default)
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        try await manager.loadModels(models)

        let layers = await manager.decoderLayerCount

        // Warm-call timing: first transcribe pays a JIT cost on macOS, so we
        // run twice and measure the second pass — that's the call shape the
        // hold-to-talk flow hits after model load.
        var warmupState = try TdtDecoderState(decoderLayers: layers)
        _ = try await manager.transcribe(samples, decoderState: &warmupState)

        var state = try TdtDecoderState(decoderLayers: layers)
        let start = Date()
        let result = try await manager.transcribe(samples, decoderState: &state)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        let normalized = result.text.lowercased()
        XCTAssertTrue(
            normalized.contains("hello") && normalized.contains("world"),
            "expected transcript to contain 'hello' and 'world'; got: \(result.text)"
        )
        print("[ParakeetBackendTests] warm transcribe latency: \(Int(elapsedMs))ms for \(samples.count / 16000)s clip → '\(result.text)'")
    }

    /// Use `say` (TTS) + `afconvert` to produce a 16 kHz mono Float32 WAV,
    /// then read it back into a `[Float]` array — the shape `ParakeetSession`
    /// feeds into `AsrManager.transcribe`.
    private func synthesize16kFloat(text: String) throws -> [Float] {
        let tmp = FileManager.default.temporaryDirectory
        let aiff = tmp.appendingPathComponent("wave-parakeet-\(UUID().uuidString).aiff")
        let wav = tmp.appendingPathComponent("wave-parakeet-\(UUID().uuidString).wav")
        defer {
            try? FileManager.default.removeItem(at: aiff)
            try? FileManager.default.removeItem(at: wav)
        }
        try run("/usr/bin/say", ["-v", "Samantha", "-o", aiff.path, text])
        try run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEF32@16000", "-c", "1", aiff.path, wav.path])

        let file = try AVAudioFile(forReading: wav)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "ParakeetBackendTests", code: 1)
        }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else {
            throw NSError(domain: "ParakeetBackendTests", code: 2)
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
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
                domain: "ParakeetBackendTests",
                code: Int(p.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(path) exit=\(p.terminationStatus)"]
            )
        }
    }
}
