import AudioToolbox
import CoreAudio
import Foundation

/// Output volume/mute via CoreAudio property listeners, lazily armed on the
/// first `volume_change` subscription. Listens on both the main element and
/// channel 1 (load-bearing for AirPods/DisplayPort devices — sketchybar trick),
/// and re-arms when the default output device changes. Also the write path
/// behind `--volume` / `ybar.volume`, so themes stop shelling `osascript`.
@MainActor
public final class AudioProvider {
    public var onEvent: ((_ name: String, _ info: String) -> Void)?

    private var currentDevice = AudioObjectID(kAudioObjectUnknown)
    private var lastVolumePercent: Int = -1
    private var deviceListenerInstalled = false
    private var started = false

    private static var defaultOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static func volumeAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    private static func muteAddress(element: UInt32) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element)
    }

    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated {
            self?.publishVolume(forced: false)
        }
    }

    public init() {}

    public func start() {
        guard !started else { return }
        started = true
        if !deviceListenerInstalled {
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &AudioProvider.defaultOutputAddress,
                .main
            ) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    self?.rearmDevice()
                }
            }
            deviceListenerInstalled = true
        }
        rearmDevice()
    }

    private func rearmDevice() {
        removeDeviceListeners()
        currentDevice = AudioProvider.defaultOutputDevice()
        guard currentDevice != kAudioObjectUnknown else { return }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var volume = AudioProvider.volumeAddress(element: element)
            var mute = AudioProvider.muteAddress(element: element)
            if AudioObjectHasProperty(currentDevice, &volume) {
                AudioObjectAddPropertyListenerBlock(currentDevice, &volume, .main, listenerBlock)
            }
            if AudioObjectHasProperty(currentDevice, &mute) {
                AudioObjectAddPropertyListenerBlock(currentDevice, &mute, .main, listenerBlock)
            }
        }
        publishVolume(forced: true)
    }

    private func removeDeviceListeners() {
        guard currentDevice != kAudioObjectUnknown else { return }
        for element in [kAudioObjectPropertyElementMain, 1] {
            var volume = AudioProvider.volumeAddress(element: element)
            var mute = AudioProvider.muteAddress(element: element)
            AudioObjectRemovePropertyListenerBlock(currentDevice, &volume, .main, listenerBlock)
            AudioObjectRemovePropertyListenerBlock(currentDevice, &mute, .main, listenerBlock)
        }
        currentDevice = AudioObjectID(kAudioObjectUnknown)
    }

    public func publishVolume(forced: Bool) {
        let percent = AudioProvider.currentVolumePercent()
        guard forced || percent != lastVolumePercent else { return }
        lastVolumePercent = percent
        onEvent?("volume_change", "\(percent)")
    }

    // MARK: - Reads

    static func defaultOutputDevice() -> AudioObjectID {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = defaultOutputAddress
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return device
    }

    public static func currentVolumePercent() -> Int {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return 0 }

        func readUInt32(_ address: inout AudioObjectPropertyAddress) -> UInt32? {
            guard AudioObjectHasProperty(device, &address) else { return nil }
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
            }
            return status == noErr ? value : nil
        }

        func readFloat32(_ address: inout AudioObjectPropertyAddress) -> Float32? {
            guard AudioObjectHasProperty(device, &address) else { return nil }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, pointer)
            }
            return status == noErr ? value : nil
        }

        let channels = [kAudioObjectPropertyElementMain, 1].map { element -> (muted: Bool?, volume: Float32?) in
            var muteAddr = muteAddress(element: element)
            var volumeAddr = volumeAddress(element: element)
            return (readUInt32(&muteAddr).map { $0 != 0 }, readFloat32(&volumeAddr))
        }
        return percent(channels: channels)
    }

    /// Pure: the percentage for the ordered channel readings (main element
    /// first, channel 1 as the fallback AirPods/DisplayPort devices need). A
    /// muted channel is 0 outright; one with no usable volume defers to the
    /// next; nothing usable is 0. Split out for testability.
    nonisolated static func percent(channels: [(muted: Bool?, volume: Float32?)]) -> Int {
        for channel in channels {
            if channel.muted == true { return 0 }
            if let volume = channel.volume, volume > 0 {
                return Int((volume * 100).rounded())
            }
        }
        return 0
    }

    // MARK: - Writes

    /// Set the default output device's level, the Windows port's
    /// AudioProvider::setVolume contract: 0 mutes and KEEPS the scalar, so
    /// unmuting later restores the previous level (the round trip the
    /// muted→0 read convention implies); anything else writes the scalar and
    /// THEN unmutes, in that order so a muted device cannot blip its old
    /// level. Arms the listeners on first use so the change publishes
    /// `volume_change` like any other.
    @discardableResult
    public func setVolume(percent: Int) -> Bool {
        let device = currentDevice != kAudioObjectUnknown
            ? currentDevice : AudioProvider.defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return false }
        let clamped = min(max(percent, 0), 100)
        let applied: Bool
        if clamped == 0 {
            // CoreAudio lets a device ship without a mute control; the
            // scalar is the only way down for those.
            applied = AudioProvider.setMuted(true, on: device)
                || AudioProvider.setScalar(0, on: device)
        } else {
            applied = AudioProvider.setScalar(Float32(clamped) / 100, on: device)
            if applied { _ = AudioProvider.setMuted(false, on: device) }
        }
        if applied { start() }
        return applied
    }

    /// Selector order for writes: the HAL's virtual main volume (what the
    /// menu-bar slider drives; present on every device the HAL can scale),
    /// then the main element's own scalar, then channels 1/2 for devices
    /// that only expose per-channel controls (AirPods, DisplayPort audio).
    private static func setScalar(_ value: Float32, on device: AudioObjectID) -> Bool {
        var virtualMain = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        if write(value, to: &virtualMain, on: device) { return true }
        var main = volumeAddress(element: kAudioObjectPropertyElementMain)
        if write(value, to: &main, on: device) { return true }
        var applied = false
        for channel: UInt32 in [1, 2] {
            var address = volumeAddress(element: channel)
            if write(value, to: &address, on: device) { applied = true }
        }
        return applied
    }

    private static func setMuted(_ muted: Bool, on device: AudioObjectID) -> Bool {
        let flag: UInt32 = muted ? 1 : 0
        var main = muteAddress(element: kAudioObjectPropertyElementMain)
        if write(flag, to: &main, on: device) { return true }
        var applied = false
        for channel: UInt32 in [1, 2] {
            var address = muteAddress(element: channel)
            if write(flag, to: &address, on: device) { applied = true }
        }
        return applied
    }

    private static func write<Value>(
        _ value: Value, to address: inout AudioObjectPropertyAddress, on device: AudioObjectID
    ) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var value = value
        let size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(device, &address, 0, nil, size, pointer)
        }
        return status == noErr
    }
}
