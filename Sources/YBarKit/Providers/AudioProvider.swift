import CoreAudio
import Foundation

/// Output volume/mute via CoreAudio property listeners, lazily armed on the
/// first `volume_change` subscription. Listens on both the main element and
/// channel 1 (load-bearing for AirPods/DisplayPort devices — sketchybar trick),
/// and re-arms when the default output device changes.
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

        for element in [kAudioObjectPropertyElementMain, 1] {
            var muteAddr = muteAddress(element: element)
            if let muted = readUInt32(&muteAddr), muted != 0 { return 0 }

            var volumeAddr = volumeAddress(element: element)
            if let volume = readFloat32(&volumeAddr), volume > 0 {
                return Int((volume * 100).rounded())
            }
        }
        return 0
    }
}
