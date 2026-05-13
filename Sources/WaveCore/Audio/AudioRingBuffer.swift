#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Bounded ring of recent PCM samples kept in memory so the orchestrator can
/// dump the last few seconds of audio after a failure. Disabled by default
/// (capacity 0); flip on by allocating with a positive `seconds` value.
public final class AudioRingBuffer: @unchecked Sendable {
    public let sampleRate: Double
    public let capacityFrames: Int
    private let queue = DispatchQueue(label: "com.wave.ringbuffer")
    private var buffer: [Float]
    private var writeIndex = 0
    private var totalFramesWritten = 0

    public init(seconds: Double = 0, sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        self.capacityFrames = max(0, Int(seconds * sampleRate))
        self.buffer = Array(repeating: 0, count: capacityFrames)
    }

    public var enabled: Bool { capacityFrames > 0 }

    public func append(_ pcmBuffer: AVAudioPCMBuffer) {
        guard enabled, let channelData = pcmBuffer.floatChannelData else { return }
        let frames = Int(pcmBuffer.frameLength)
        let channel = channelData[0]
        queue.sync {
            for i in 0..<frames {
                buffer[writeIndex] = channel[i]
                writeIndex = (writeIndex + 1) % capacityFrames
            }
            totalFramesWritten += frames
        }
    }

    /// Returns the most recent `seconds` of audio in chronological order.
    public func snapshot(seconds: Double) -> [Float] {
        guard enabled else { return [] }
        let want = min(capacityFrames, Int(seconds * sampleRate))
        return queue.sync {
            let available = min(totalFramesWritten, capacityFrames)
            let count = min(want, available)
            guard count > 0 else { return [] }
            var out = [Float](repeating: 0, count: count)
            let start = (writeIndex - count + capacityFrames) % capacityFrames
            for i in 0..<count {
                out[i] = buffer[(start + i) % capacityFrames]
            }
            return out
        }
    }
}
#endif
