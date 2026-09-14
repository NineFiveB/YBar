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
        percent(channels: channelReadings())
    }

    /// The default output device's raw readings, main element first and channel
    /// 1 as the fallback AirPods/DisplayPort devices need. Callers that must
    /// tell "muted" from "turned down" (the `+N`/`-N` step base) read these
    /// instead of `currentVolumePercent()`, which folds both into 0.
    static func channelReadings() -> [(muted: Bool?, volume: Float32?)] {
        let device = defaultOutputDevice()
        guard device != kAudioObjectUnknown else { return [] }

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

        return [kAudioObjectPropertyElementMain, 1].map { element -> (muted: Bool?, volume: Float32?) in
            var muteAddr = muteAddress(element: element)
            var volumeAddr = volumeAddress(element: element)
            return (readUInt32(&muteAddr).map { $0 != 0 }, readFloat32(&volumeAddr))
        }
    }

    /// Pure: the percentage for the ordered channel readings (main element
    /// first, channel 1 as the fallback AirPods/DisplayPort devices need). A
    /// muted channel is 0 outright; one with no usable volume defers to the
    /// next; nothing usable is 0. Split out for testability. This is the
    /// DISPLAY convention (what a theme renders and what `volume_change`
    /// publishes) — writes resolve against `scalarPercent` instead.
    nonisolated static func percent(channels: [(muted: Bool?, volume: Float32?)]) -> Int {
        isMuted(channels: channels) ? 0 : scalarPercent(channels: channels)
    }

    /// Pure: is the device muted, scanning in the same order `percent` does —
    /// a channel that already reported audible volume settles the question
    /// before a later channel's mute flag is consulted.
    nonisolated static func isMuted(channels: [(muted: Bool?, volume: Float32?)]) -> Bool {
        for channel in channels {
            if channel.muted == true { return true }
            if let volume = channel.volume, volume > 0 { return false }
        }
        return false
    }

    /// Pure: the device's volume SCALAR as a percentage, ignoring mute — what
    /// AppleScript's `output volume of (get volume settings)` reports, and the
    /// level CoreAudio keeps while muted. A step must resolve against this, not
    /// against `percent`: basing `+4` on the muted display value would set 4%
    /// and destroy the level the user muted at.
    nonisolated static func scalarPercent(channels: [(muted: Bool?, volume: Float32?)]) -> Int {
        for channel in channels {
            if let volume = channel.volume, volume > 0 {
                return Int((volume * 100).rounded())
            }
        }
        return 0
    }

    /// Pure: the level `--volume ±N` resolves to, or nil for "leave the device
    /// alone". Stepping UP from a muted device resumes from the kept scalar
    /// (60% muted, `+4` → 64%, unmuted by the write) instead of from the
    /// display 0; stepping DOWN while muted is a no-op, because lowering an
    /// already-silent device may not silently discard the level unmuting is
    /// supposed to restore.
    nonisolated static func stepTarget(delta: Int, scalar: Int, muted: Bool) -> Int? {
        if muted && delta <= 0 { return nil }
        return min(max(scalar + delta, 0), 100)
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

    /// `--volume +N` / `-N`, the form scroll-to-adjust uses. The base is the
    /// device scalar, so the step matches what the `osascript` line it replaced
    /// did (`set volume output volume ((output volume of (get volume settings))
    /// + 4)`, which also reads through mute); true when nothing needed writing
    /// or the write landed.
    @discardableResult
    public func step(by delta: Int) -> Bool {
        let channels = AudioProvider.channelReadings()
        guard let target = AudioProvider.stepTarget(
            delta: delta,
            scalar: AudioProvider.scalarPercent(channels: channels),
            muted: AudioProvider.isMuted(channels: channels)) else { return true }
        return setVolume(percent: target)
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
