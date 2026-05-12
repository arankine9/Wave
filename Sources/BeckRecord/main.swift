import Foundation
import AVFoundation
import BeckCore

// CLI harness: record N seconds from the system mic, transcribe via the
// production ParakeetBackend (same voice-processing wiring the .app uses),
// print the transcript on stdout, timing + diagnostics on stderr.
//
// Usage:
//   swift run beck-record [seconds] [--no-voice-processing]
//
// Default seconds = 5. Voice processing is on by default.

let args = CommandLine.arguments.dropFirst()
var seconds: Double = 5
var voiceProcessing: Bool = false

for arg in args {
    if let n = Double(arg), n > 0, n < 600 {
        seconds = n
    } else if arg == "--voice-processing" {
        voiceProcessing = true
    } else if arg == "-h" || arg == "--help" {
        print("""
        beck-record — record from mic, transcribe with Parakeet.

          swift run beck-record [seconds] [--voice-processing]

        Defaults: 5 seconds, voice processing OFF (broken on macOS — see
        ParakeetBackend.swift).
        Transcript prints to stdout; diagnostics print to stderr.
        """)
        exit(0)
    } else {
        FileHandle.standardError.write(Data("unknown arg: \(arg)\n".utf8))
        exit(2)
    }
}

FileHandle.standardError.write(Data("[beck-record] recording \(seconds)s, voice processing = \(voiceProcessing)\n".utf8))

let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
FileHandle.standardError.write(Data("[beck-record] mic permission status: \(micStatus.rawValue) (.authorized=3)\n".utf8))

let backend = ParakeetBackend(config: ParakeetBackend.Config(
    enableVoiceProcessing: voiceProcessing,
    verboseLog: true
))

let runner = Task {
    if micStatus != .authorized {
        FileHandle.standardError.write(Data("[beck-record] requesting mic permission...\n".utf8))
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        FileHandle.standardError.write(Data("[beck-record] mic permission granted: \(granted)\n".utf8))
        if !granted {
            FileHandle.standardError.write(Data("[beck-record] ABORT: mic not authorized. Grant via System Settings → Privacy & Security → Microphone for Terminal (or whatever runs this binary).\n".utf8))
            exit(1)
        }
    }
    do {
        let session = try await backend.startSession()
        FileHandle.standardError.write(Data("[beck-record] session started — speak now\n".utf8))
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        FileHandle.standardError.write(Data("[beck-record] recording done, transcribing\n".utf8))
        let text = try await session.finalize()
        print(text)
        FileHandle.standardError.write(Data("[beck-record] done\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("[beck-record] FAILED: \(error)\n".utf8))
        exit(1)
    }
}

// Keep the run loop alive — AVAudioEngine's tap callbacks dispatch via the
// audio I/O thread, but the model load runs on a Task that needs the runtime.
RunLoop.main.run()
_ = runner
