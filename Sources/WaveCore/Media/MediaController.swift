import Foundation
#if canImport(CoreAudio)
import CoreAudio
#endif

/// Silences whatever is playing on the default output (Music, Spotify,
/// browser tabs, Podcasts, AirPlay) for the duration of a dictation cycle.
///
/// "Mute, don't pause." Pausing requires either the MediaRemote private
/// framework (blocked for third-party apps since macOS 15.4) or Apple
/// Events scripting (Automation TCC prompts users won't accept). Muting
/// the default output device is a public CoreAudio API that needs no
/// TCC permissions, works on every macOS version, and works for every
/// audio source — including system sounds and AirPlay sinks. This is
/// the same approach Wispr Flow ships.
public protocol MediaController: Sendable {
    /// Mute the default output (if audio is currently playing and the
    /// device isn't already muted). Returns true if a mute was actually
    /// applied, so the caller knows whether to restore later.
    func pauseIfPlaying() async -> Bool

    /// Restore the prior mute state. No-op if `pauseIfPlaying` didn't mute.
    func resume() async
}

/// Test/default-disabled implementation.
public final class NoopMediaController: MediaController {
    public init() {}
    public func pauseIfPlaying() async -> Bool { false }
    public func resume() async {}
}

#if canImport(CoreAudio)

/// CoreAudio-backed mute controller. Targets the user's default output
/// device — whatever audio is going to the speakers/headphones/AirPlay
/// receiver, that's what gets silenced.
///
/// Behavior follows Wispr Flow's rule:
///   - if the device is already muted, leave it alone (no-op);
///   - if nothing is actively playing, leave it alone (no-op);
///   - otherwise mute on record start, restore on record stop.
///
/// Some Bluetooth outputs (notably AirPods) don't expose a writable
/// per-device mute property. For those we fall back to setting the
/// per-device output volume to 0 and restoring the prior volume.
public final class OutputMuteMediaController: MediaController, @unchecked Sendable {

    private enum MuteAction: Sendable {
        case mutedDevice(AudioDeviceID)
        case loweredVolume(AudioDeviceID, channels: [(channel: AudioObjectPropertyElement, prior: Float32)])
    }

    private let lock = NSLock()
    private var lastAction: MuteAction?

    public init() {}

    public func pauseIfPlaying() async -> Bool {
        guard let device = defaultOutputDevice() else { return false }
        // Don't fight the user's manual mute or jump in when nothing is
        // playing — matches Wispr Flow's behavior.
        if currentMute(device) == true { return false }
        guard deviceIsRunning(device) else { return false }

        if setMute(device, value: true) {
            store(.mutedDevice(device))
            return true
        }
        // The device doesn't accept programmatic mute. Fall back to
        // zeroing the volume on each output channel that supports it,
        // remembering the prior values so we can restore them.
        if let channels = zeroAllOutputChannels(device) {
            store(.loweredVolume(device, channels: channels))
            return true
        }
        return false
    }

    public func resume() async {
        guard let action = takeAction() else { return }
        switch action {
        case .mutedDevice(let device):
            _ = setMute(device, value: false)
        case .loweredVolume(let device, let channels):
            for (channel, prior) in channels {
                _ = setVolume(device, channel: channel, value: prior)
            }
        }
    }

    // MARK: - state

    private func store(_ action: MuteAction) {
        lock.withLock { lastAction = action }
    }

    private func takeAction() -> MuteAction? {
        lock.withLock {
            let a = lastAction
            lastAction = nil
            return a
        }
    }

    // MARK: - CoreAudio helpers

    private func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private func currentMute(_ device: AudioDeviceID) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value != 0 : nil
    }

    private func setMute(_ device: AudioDeviceID, value: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var v: UInt32 = value ? 1 : 0
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<UInt32>.size), &v
        )
        return status == noErr
    }

    private func deviceIsRunning(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    /// Bluetooth fallback: drop each per-channel output volume to 0,
    /// remembering the prior level so we can restore on stop.
    private func zeroAllOutputChannels(_ device: AudioDeviceID) -> [(channel: AudioObjectPropertyElement, prior: Float32)]? {
        // Try the master element first; many devices accept it.
        if let prior = currentVolume(device, channel: kAudioObjectPropertyElementMain),
           setVolume(device, channel: kAudioObjectPropertyElementMain, value: 0) {
            return [(kAudioObjectPropertyElementMain, prior)]
        }
        // Otherwise enumerate per-channel.
        var channels: [(AudioObjectPropertyElement, Float32)] = []
        // Channels 1..8 covers the common stereo / multichannel cases.
        for channel in 1...8 {
            let element = AudioObjectPropertyElement(channel)
            guard let prior = currentVolume(device, channel: element) else { continue }
            if setVolume(device, channel: element, value: 0) {
                channels.append((element, prior))
            }
        }
        return channels.isEmpty ? nil : channels
    }

    private func currentVolume(_ device: AudioDeviceID, channel: AudioObjectPropertyElement) -> Float32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    @discardableResult
    private func setVolume(_ device: AudioDeviceID, channel: AudioObjectPropertyElement, value: Float32) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: channel
        )
        guard AudioObjectHasProperty(device, &address) else { return false }
        var v = value
        let status = AudioObjectSetPropertyData(
            device, &address, 0, nil,
            UInt32(MemoryLayout<Float32>.size), &v
        )
        return status == noErr
    }
}

#endif
