import CoreLocation
import Foundation
import Testing
@testable import YBarKit

// Provider contract tests. The OS-driven halves (distributed notifications,
// CoreAudio listeners, NWPathMonitor, host statistics) cannot run headless,
// so what is pinned here is the pure logic each provider hands to the event
// bus — the same contracts docs/WINDOWS-PORT.md fixes for the port.

@Suite struct MediaTerminationTests {
    private let playing: [String: String] = [
        "MEDIA_APP": "Spotify",
        "MEDIA_STATE": "playing",
        "MEDIA_TITLE": "Song",
        "MEDIA_ARTIST": "Artist",
        "MEDIA_ALBUM": "Album",
    ]

    @Test func quittingTheSourcePlayerYieldsStopped() {
        let env = MediaProvider.reduce(termination: "com.spotify.client", current: playing)
        #expect(env?["MEDIA_STATE"] == "stopped")
        #expect(env?["MEDIA_APP"] == "Spotify")
        // One shape for every media_change: the track fields are present, empty.
        #expect(env?["MEDIA_TITLE"] == "")
        #expect(env?["MEDIA_ARTIST"] == "")
        #expect(env?["MEDIA_ALBUM"] == "")
    }

    @Test func quittingTheOtherPlayerLeavesPlaybackAlone() {
        // Music quitting while Spotify plays must not blank the pill.
        #expect(MediaProvider.reduce(termination: "com.apple.Music", current: playing) == nil)
    }

    @Test func unrelatedAppsAndIdleCacheAreIgnored() {
        #expect(MediaProvider.reduce(termination: "com.apple.Safari", current: playing) == nil)
        #expect(MediaProvider.reduce(termination: "com.spotify.client", current: [:]) == nil)
        #expect(MediaProvider.reduce(termination: "", current: playing) == nil)
    }
}

@Suite struct LocationAuthorizationTests {
    @Test func grantLandingTriggersRefresh() {
        // The user clicked Allow (or flipped the toggle in System Settings).
        #expect(NetworkProvider.authorizationUnlocksSSID(previous: .notDetermined, current: .authorizedAlways))
        #expect(NetworkProvider.authorizationUnlocksSSID(previous: .denied, current: .authorizedAlways))
    }

    @Test func initialCallbackAndNonGrantsDoNot() {
        // CLLocationManager reports the existing status as soon as a delegate
        // is set; that SSID (or its absence) is already published.
        #expect(!NetworkProvider.authorizationUnlocksSSID(previous: nil, current: .authorizedAlways))
        #expect(!NetworkProvider.authorizationUnlocksSSID(previous: .notDetermined, current: .denied))
        #expect(!NetworkProvider.authorizationUnlocksSSID(previous: .authorizedAlways, current: .authorizedAlways))
        #expect(!NetworkProvider.authorizationUnlocksSSID(previous: .authorizedAlways, current: .denied))
    }
}

@Suite struct GPUStatisticsTests {
    @Test func appleSiliconKeysReduceToUtilizationAndMemory() {
        // Verbatim shape of an AGX accelerator's PerformanceStatistics.
        let agx: [String: Any] = [
            "Device Utilization %": 47,
            "Renderer Utilization %": 47,
            "Tiler Utilization %": 31,
            "In use system memory": 1_607_532_544,
            "Alloc system memory": 4_252_401_664,
        ]
        let sample = SystemStatsProvider.gpuSample(performance: agx)
        #expect(sample?.utilization == 0.47)
        #expect(sample?.memoryUsedBytes == 1_607_532_544)
    }

    @Test func intelKeyIsTheFallbackAndMemoryIsOptional() {
        let intel: [String: Any] = ["GPU Activity(%)": 12]
        let sample = SystemStatsProvider.gpuSample(performance: intel)
        #expect(sample?.utilization == 0.12)
        #expect(sample?.memoryUsedBytes == nil)
    }

    @Test func noUtilizationKeyMeansNoSample() {
        // Callers omit the GPU_* keys entirely rather than publish zeros.
        #expect(SystemStatsProvider.gpuSample(performance: [:]) == nil)
        #expect(SystemStatsProvider.gpuSample(performance: ["In use system memory": 4096]) == nil)
    }

    @Test func utilizationIsClamped() {
        #expect(SystemStatsProvider.gpuSample(performance: ["Device Utilization %": 250])?.utilization == 1)
        #expect(SystemStatsProvider.gpuSample(performance: ["Device Utilization %": -3])?.utilization == 0)
    }
}
