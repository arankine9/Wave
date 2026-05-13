#if canImport(CoreAudio) && canImport(AudioToolbox)
import CoreAudio
import AudioToolbox
import Foundation

/// A single CoreAudio input-capable device.
public struct AudioInputDevice: Sendable, Equatable, Hashable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let transportType: UInt32

    public var isBuiltIn: Bool {
        transportType == kAudioDeviceTransportTypeBuiltIn
    }
}

/// CoreAudio device enumeration helpers. All calls are synchronous reads of
/// HAL properties — safe to call from any thread, but expect a few ms of work.
public enum AudioInputDevices {
    /// Every device that exposes at least one input stream.
    public static func available() -> [AudioInputDevice] {
        let allIDs = allDeviceIDs()
        return allIDs.compactMap { id in
            guard hasInputStreams(id) else { return nil }
            guard let uid = stringProperty(id, selector: kAudioDevicePropertyDeviceUID) else { return nil }
            let name = stringProperty(id, selector: kAudioObjectPropertyName) ?? "Unknown"
            let transport: UInt32 = u32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
            return AudioInputDevice(id: id, uid: uid, name: name, transportType: transport)
        }
    }

    /// First input device with the built-in transport type.
    public static func builtIn() -> AudioInputDevice? {
        available().first(where: { $0.isBuiltIn })
    }

    public static func find(uid: String) -> AudioInputDevice? {
        available().first(where: { $0.uid == uid })
    }

    public static func systemDefaultID() -> AudioDeviceID? {
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var id = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &id
        )
        return status == noErr && id != 0 ? id : nil
    }

    // MARK: - Internals

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard sizeStatus == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &ids
        )
        guard status == noErr else { return [] }
        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var unmanaged: Unmanaged<CFString>?
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &unmanaged)
        guard status == noErr, let cf = unmanaged?.takeRetainedValue() else { return nil }
        return cf as String
    }

    private static func u32Property(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<UInt32>.size)
        var value: UInt32 = 0
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
#endif
