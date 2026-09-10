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
