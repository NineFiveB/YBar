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

@Suite struct AudioPercentTests {
    @Test func mutedIsZeroRegardlessOfVolume() {
        #expect(AudioProvider.percent(channels: [(muted: true, volume: 0.8)]) == 0)
        // A muted channel 1 wins even when the main element had no reading.
        #expect(AudioProvider.percent(channels: [(muted: nil, volume: nil), (muted: true, volume: 0.8)]) == 0)
    }

    @Test func mainElementWinsAndChannelOneIsTheFallback() {
        #expect(AudioProvider.percent(channels: [(muted: false, volume: 0.5), (muted: false, volume: 0.9)]) == 50)
        // AirPods/DisplayPort devices expose no main-element volume.
        #expect(AudioProvider.percent(channels: [(muted: nil, volume: nil), (muted: false, volume: 0.73)]) == 73)
        // A zero main volume defers too (the device reports per channel).
        #expect(AudioProvider.percent(channels: [(muted: false, volume: 0), (muted: false, volume: 0.25)]) == 25)
    }

    @Test func nothingUsableIsZero() {
        #expect(AudioProvider.percent(channels: []) == 0)
        #expect(AudioProvider.percent(channels: [(muted: nil, volume: nil), (muted: nil, volume: nil)]) == 0)
        #expect(AudioProvider.percent(channels: [(muted: false, volume: 0)]) == 0)
    }

    /// The scalar reader keeps the level a muted device is holding — the
    /// display convention above folds it to 0, which is right for rendering
    /// and wrong as a step base.
    @Test func scalarPercentIgnoresMute() {
        #expect(AudioProvider.scalarPercent(channels: [(muted: true, volume: 0.6)]) == 60)
        #expect(AudioProvider.isMuted(channels: [(muted: true, volume: 0.6)]))
        #expect(AudioProvider.scalarPercent(channels: [(muted: nil, volume: nil), (muted: true, volume: 0.6)]) == 60)
        #expect(!AudioProvider.isMuted(channels: [(muted: false, volume: 0.6)]))
        #expect(AudioProvider.scalarPercent(channels: []) == 0)
    }

    /// `--volume +4` on a Mac muted at 60%: resume at 64%, not the 4% the old
    /// `currentVolumePercent() + delta` base produced (which also overwrote the
    /// kept scalar, so a later system unmute had nothing to restore). A step
    /// down while muted leaves the device alone.
    @Test func stepResolvesAgainstTheKeptScalarWhileMuted() {
        #expect(AudioProvider.stepTarget(delta: 4, scalar: 60, muted: true) == 64)
        #expect(AudioProvider.stepTarget(delta: -4, scalar: 60, muted: true) == nil)
        #expect(AudioProvider.stepTarget(delta: 4, scalar: 60, muted: false) == 64)
        #expect(AudioProvider.stepTarget(delta: -4, scalar: 2, muted: false) == 0)
        #expect(AudioProvider.stepTarget(delta: 40, scalar: 90, muted: false) == 100)
    }
}

@Suite struct WifiScanMergeTests {
    @Test func keepsTheStrongestSightingAndMarksKnown() {
        let rows = WifiScan.merge(
            sightings: [
                .init(name: "Home", rssi: -70),
                .init(name: "Home", rssi: -40),
                .init(name: "Cafe", rssi: -55),
            ],
            currentSSID: "Home",
            profiles: [.init(name: "Home", hotspot: false)])
        #expect(rows.count == 2)
        #expect(rows[0] == WifiScanRow(
            name: "Home", rssi: -40, current: true, known: true, hotspot: false))
        #expect(rows[1].name == "Cafe")
        #expect(!rows[1].known)
        #expect(!rows[1].hotspot)
    }

    @Test func savedHotspotIsListedWhenItIsNotBroadcasting() {
        let rows = WifiScan.merge(
            sightings: [.init(name: "Home", rssi: -50)],
            currentSSID: "Home",
            profiles: [
                .init(name: "Home", hotspot: false),
                .init(name: "iPhone", hotspot: true),
            ])
        #expect(rows.contains {
            $0.name == "iPhone" && $0.hotspot && $0.known
                && !$0.current && $0.rssi == WifiScan.absentRSSI
        })
    }

    @Test func unreadableHotspotFlagIsNotGuessed() {
        let rows = WifiScan.merge(
            sightings: [],
            currentSSID: nil,
            profiles: [.init(name: "iPhone", hotspot: nil)])
        #expect(rows.isEmpty)
    }

    @Test func redactionIsNetworksOnTheAirThatNoneCouldName() {
        #expect(WifiScan.isRedacted(scanned: 22, named: 0))
        #expect(!WifiScan.isRedacted(scanned: 22, named: 22))
        // One hidden-SSID network is a hidden network, not a missing grant.
        #expect(!WifiScan.isRedacted(scanned: 22, named: 21))
        // Wi-Fi off or a failed pass: nothing to name.
        #expect(!WifiScan.isRedacted(scanned: 0, named: 0))
    }

    @Test func tsvMatchesThePopupParser() {
        let rows = WifiScan.merge(
            sightings: [.init(name: "Home\tNet", rssi: -42)],
            currentSSID: "Home\tNet",
            profiles: [.init(name: "Home\tNet", hotspot: false)])
        #expect(WifiScan.tsv(rows) == "1\tHome Net\t-42\t1\t0\t1")
    }

    @Test func passwordJoinKeepsTheSecretOutOfTheArguments() {
        let secret = "super-secret-value"
        let args = WifiScan.airportJoinArguments(interface: "en0", name: "Cafe", password: secret)
        #expect(args == ["-setairportnetwork", "en0", "Cafe", "-"])
        #expect(!args.contains(secret))
        #expect(WifiScan.airportJoinArguments(interface: "en0", name: "Cafe", password: nil)
            == ["-setairportnetwork", "en0", "Cafe"])
    }

    @Test func redactedOutputDropsThePassword() {
        let secret = "super-secret-value"
        #expect(WifiScan.redacted("echo \(secret) done", password: secret) == "echo  done")
        #expect(WifiScan.redacted("Failed to join Cafe.", password: nil) == "Failed to join Cafe.")
        #expect(WifiScan.redacted("Failed to join Cafe.", password: "") == "Failed to join Cafe.")
    }
}

@Suite struct WifiJoinVerdictTests {
    @Test func silenceWithExitZeroIsTheOnlySuccess() {
        #expect(!WifiScan.joinRejected(code: 0, output: ""))
        // The trimmed child output can still carry a stray newline.
        #expect(!WifiScan.joinRejected(code: 0, output: "\n"))
    }

    @Test func exitZeroRefusalsAreStillRefusals() {
        // networksetup exits 0 for each of these; none says "failed".
        for message in [
            "Could not find network Cafe.",
            "You cannot join a network when Wi-Fi power is off.",
            "All Wi-Fi network services are disabled.",
            "Failed to join network Cafe.",
        ] {
            #expect(WifiScan.joinRejected(code: 0, output: message), "\(message)")
        }
    }

    @Test func nonZeroExitIsARefusalEvenWhenSilent() {
        #expect(WifiScan.joinRejected(code: 1, output: ""))
    }

    @Test func openNetworkStaysUnsecured() {
        let rows = WifiScan.merge(
            sightings: [.init(name: "Cafe", rssi: -60, secure: false)],
            currentSSID: nil,
            profiles: [])
        #expect(rows.count == 1)
        #expect(rows[0].secure == false)
        #expect(WifiScan.tsv(rows) == "0\tCafe\t-60\t0\t0\t0")
    }
}

@Suite struct NetworkInfoTests {
    @Test func offlineIsEmpty() {
        #expect(NetworkProvider.info(satisfied: false, isWifi: true, ssid: "Home") == "")
    }

    @Test func ssidOnlyOnWifiWhenReadable() {
        #expect(NetworkProvider.info(satisfied: true, isWifi: true, ssid: "Home") == "Home")
        // No Location grant: CoreWLAN hands back nil and the widget degrades.
        #expect(NetworkProvider.info(satisfied: true, isWifi: true, ssid: nil) == "connected")
        // Wired: an SSID from a still-associated Wi-Fi interface is not the path.
        #expect(NetworkProvider.info(satisfied: true, isWifi: false, ssid: "Home") == "connected")
    }
}

@Suite struct MediaEnvironmentTests {
    @Test func notificationMapsToMediaKeys() {
        let userInfo: [AnyHashable: Any] = [
            "Player State": "Playing", "Name": "Song", "Artist": "Artist", "Album": "Album",
            "Total Time": 240_000,
        ]
        let env = MediaProvider.environment(app: "Music", userInfo: userInfo)
        #expect(env == [
            "MEDIA_APP": "Music", "MEDIA_STATE": "playing",
            "MEDIA_TITLE": "Song", "MEDIA_ARTIST": "Artist", "MEDIA_ALBUM": "Album",
        ])
    }

    @Test func missingNotificationFieldsAreEmptyNotAbsent() {
        let env = MediaProvider.environment(app: "Spotify", userInfo: ["Player State": "Paused"])
        #expect(env["MEDIA_STATE"] == "paused")
        #expect(env["MEDIA_TITLE"] == "")
        #expect(env["MEDIA_ARTIST"] == "")
        #expect(env["MEDIA_ALBUM"] == "")
    }

    @Test func seedLineIsTabJoinedSoPunctuationSurvives() {
        let env = MediaProvider.seedEnvironment(
            app: "Spotify", output: "playing\tSong, Pt. 1 | Remix\tA, B\tAlbum\n")
        #expect(env?["MEDIA_STATE"] == "playing")
        #expect(env?["MEDIA_TITLE"] == "Song, Pt. 1 | Remix")
        #expect(env?["MEDIA_ARTIST"] == "A, B")
        #expect(env?["MEDIA_ALBUM"] == "Album")
    }

    @Test func seedOnlyReportsActivePlayback() {
        #expect(MediaProvider.seedEnvironment(app: "Music", output: "stopped\t\t\t\n") == nil)
        #expect(MediaProvider.seedEnvironment(app: "Music", output: "") == nil)
        #expect(MediaProvider.seedEnvironment(app: "Music", output: "execution error: ...") == nil)
        // A paused player with no readable track still shows the pill.
        let paused = MediaProvider.seedEnvironment(app: "Music", output: "paused")
        #expect(paused?["MEDIA_STATE"] == "paused")
        #expect(paused?["MEDIA_TITLE"] == "")
    }
}

@Suite struct CPUDeltaTests {
    @Test func firstSampleHasNoBaseline() {
        #expect(SystemStatsProvider.cpuFraction(previous: nil, current: (busy: 10, total: 100)) == nil)
    }

    @Test func fractionIsTheBusyShareOfElapsedTicks() {
        let fraction = SystemStatsProvider.cpuFraction(
            previous: (busy: 100, total: 1000), current: (busy: 150, total: 1100))
        #expect(fraction == 0.5)
    }

    @Test func stalledClockAndOverrunAreHandled() {
        // Same tick count twice (timer fired before the kernel advanced).
        #expect(SystemStatsProvider.cpuFraction(
            previous: (busy: 100, total: 1000), current: (busy: 100, total: 1000)) == nil)
        // Busy outpacing total cannot exceed 1.
        #expect(SystemStatsProvider.cpuFraction(
            previous: (busy: 100, total: 1000), current: (busy: 300, total: 1100)) == 1)
    }
}
