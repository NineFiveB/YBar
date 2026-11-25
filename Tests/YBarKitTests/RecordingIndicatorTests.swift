import CoreGraphics
import Foundation
import Testing
@testable import YBarKit

/// The screen-recording indicator is found in the window list by what the
/// list gives without a grant — owner, layer, bounds — never by name, which
/// comes back empty without Screen Recording. These pin that matcher against
/// what the list actually looks like, so a change to the shape of the
/// heuristic has to be deliberate.
///
/// macOS draws one indicator per display. The second half pins what that
/// means: each one resolved to its own display and reported in that
/// display's points, whatever the arrangement and whatever order the list
/// came back in.
@MainActor
@Suite struct RecordingIndicatorTests {
    private func window(owner: String, layer: Int, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat)
        -> [String: Any] {
        [
            kCGWindowOwnerName as String: owner,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: CGFloat],
        ]
    }

    private func overlay(x: CGFloat, y: CGFloat, w: CGFloat = 28, h: CGFloat = 28) -> [String: Any] {
        window(owner: "Window Server", layer: 2_147_483_630, x: x, y: y, w: w, h: h)
    }

    private func indicator(_ display: Int, _ x: CGFloat, _ y: CGFloat) -> RecordingIndicator {
        RecordingIndicator(display: display, frame: CGRect(x: x, y: y, width: 28, height: 28))
    }

    /// The window list's space: y down from the primary's top-left.
    private let builtIn = CGRect(x: 0, y: 0, width: 1512, height: 982)
    /// A Sidecar arranged to the left of the built-in, tops aligned.
    private let sidecar = CGRect(x: -1103, y: 0, width: 1103, height: 802)

    /// Measured on macOS 27 with a Sidecar attached on the left: the arrow
    /// cursor's window first, each indicator listed twice, and the Sidecar's
    /// hanging 6pt past its own right edge and 6pt above its top.
    private var live: [[String: Any]] {
        [
            overlay(x: 1049, y: 91, w: 28, h: 40),
            overlay(x: -22, y: -6),
            overlay(x: -22, y: -6),
            overlay(x: 1481, y: 3),
            overlay(x: 1481, y: 3),
            window(owner: "MenuBarAgent", layer: 25, x: 0, y: 0, w: 1512, h: 33),
            window(owner: "YBar", layer: 26, x: 0, y: 0, w: 1512, h: 40),
            window(owner: "YBar", layer: 26, x: -1103, y: 0, w: 1103, h: 40),
        ]
    }

    private var both: [RecordingIndicator] { [indicator(1, 1481, 3), indicator(2, 1081, -6)] }

    // MARK: - One display

    /// Measured on macOS 27 while `screencapture -v` ran.
    @Test func findsTheIndicatorAsMeasured() {
        let list = [
            window(owner: "MenuBarAgent", layer: 25, x: 0, y: 0, w: 1512, h: 33),
            overlay(x: 1481, y: 3),
            window(owner: "YBar", layer: 26, x: 0, y: 0, w: 1512, h: 40),
        ]
        #expect(RecordingIndicatorProvider.indicators(in: list, displays: [builtIn])
                == [indicator(1, 1481, 3)])
    }

    @Test func nothingWhenNoRecordingRuns() {
        let list = [
            window(owner: "MenuBarAgent", layer: 25, x: 0, y: 0, w: 1512, h: 33),
            window(owner: "YBar", layer: 26, x: 0, y: 0, w: 1512, h: 40),
        ]
        #expect(RecordingIndicatorProvider.indicators(in: list, displays: [builtIn]).isEmpty)
    }

    /// The WindowServer owns other overlays (the whole bar strip at layer 25,
    /// the arrow cursor, a wide notch cover). None of them is a small square
    /// at a far-above-app layer in the top strip, and none may count.
    @Test func otherWindowServerWindowsDoNotCount() {
        let list = [
            window(owner: "Window Server", layer: 25, x: 0, y: 0, w: 1512, h: 33),
            overlay(x: 600, y: 0, w: 300, h: 32),
            overlay(x: 1481, y: 400),
            overlay(x: 1049, y: 10, w: 28, h: 40),
            window(owner: "SomeApp", layer: 2_147_483_630, x: 1481, y: 3, w: 28, h: 28),
        ]
        #expect(RecordingIndicatorProvider.indicators(in: list, displays: [builtIn]).isEmpty)
    }

    /// `update_mask` bits are positions in this list: the event keeps its.
    @Test func theEventIsBuiltIn() {
        #expect(EventBus.builtinEvents.contains("recording_change"))
        #expect(EventBus.builtinEvents.firstIndex(of: "recording_change") == 21)
    }

    // MARK: - Several displays

    /// The report that started this: a Sidecar left of a notched MacBook.
    /// The first window in the list was the Sidecar's, at desktop x = -22,
    /// and a clock that read that against display 1's bar opened by the
    /// width of a screen.
    @Test func sidecarLeftOfTheNotchedBuiltInAsMeasured() {
        #expect(RecordingIndicatorProvider.indicators(in: live, displays: [builtIn, sidecar]) == both)
    }

    @Test func windowListOrderNeverChangesTheAnswer() {
        let displays = [builtIn, sidecar]
        let expected = RecordingIndicatorProvider.environment(for: both)
        var list = live
        for _ in 0..<live.count {
            list.append(list.removeFirst())
            for candidate in [list, Array(list.reversed())] {
                let found = RecordingIndicatorProvider.indicators(in: candidate, displays: displays)
                #expect(found == both)
                #expect(RecordingIndicatorProvider.environment(for: found) == expected)
            }
        }
    }

    @Test func anOverhangingIndicatorBelongsToTheDisplayItMostlyCovers() {
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: -22, y: -6)], displays: [builtIn, sidecar]) == [indicator(2, 1081, -6)])
    }

    @Test func externalRightOfThePrimary() {
        let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 4050, y: 3)], displays: [builtIn, external]) == [indicator(2, 2538, 3)])
    }

    /// The top strip is the display's own. A desktop-wide `y < 44` matched
    /// anything at all on a display above the primary and nothing on one
    /// below it.
    @Test func displaysAboveAndBelowUseTheirOwnTopStrip() {
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 1889, y: -1077), overlay(x: 500, y: -600)],
            displays: [builtIn, above]) == [indicator(2, 1889, 3)])

        let below = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 1889, y: 985)], displays: [builtIn, below]) == [indicator(2, 1889, 3)])

        let sidecarBelow = CGRect(x: 0, y: 982, width: 1103, height: 802)
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 1081, y: 976)], displays: [builtIn, sidecarBelow])
            == [indicator(2, 1081, -6)])
    }

    @Test func aWindowOnNoDisplayIsDropped() {
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 5000, y: 3)], displays: [builtIn, sidecar]).isEmpty)
        #expect(RecordingIndicatorProvider.indicators(in: [overlay(x: 1481, y: 3)], displays: []).isEmpty)
    }

    // MARK: - The pointer

    /// While the screen is captured the cursor is a WindowServer window on
    /// the indicator's own layer, sized by the cursor image. A hand (32×32)
    /// or an I-beam (23×22) in the top strip passes every shape test, and the
    /// clock used to follow the mouse.
    @Test func theCursorNeverCounts() {
        let hand = overlay(x: 184, y: 4, w: 32, h: 32)
        let pointer = CGPoint(x: 200.3, y: 20.2)
        #expect(RecordingIndicatorProvider.indicators(
            in: [hand], displays: [builtIn], pointer: pointer).isEmpty)
        #expect(RecordingIndicatorProvider.indicators(
            in: [hand] + live, displays: [builtIn, sidecar], pointer: pointer) == both)

        let iBeam = overlay(x: 700, y: 10, w: 23, h: 22)
        #expect(RecordingIndicatorProvider.indicators(
            in: [iBeam], displays: [builtIn], pointer: CGPoint(x: 705, y: 14)).isEmpty)

        // On the Sidecar, where the strip is inside app chrome.
        let onSidecar = overlay(x: -612, y: 40, w: 32, h: 32)
        #expect(RecordingIndicatorProvider.indicators(
            in: [onSidecar] + live, displays: [builtIn, sidecar],
            pointer: CGPoint(x: -600, y: 48)) == both)

        // Without the pointer there is nothing to tell it by — which is why
        // poll() always passes one.
        #expect(RecordingIndicatorProvider.indicators(in: [hand], displays: [builtIn]).count == 1)
    }

    /// The pointer reaching the dot must not switch the recording "off": an
    /// indicator already reported stays one. A cursor never was reported, so
    /// it never gets that pass.
    @Test func aKnownIndicatorSurvivesThePointer() {
        let dot = indicator(1, 1481, 3)
        let over = CGPoint(x: 1495, y: 17)
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 1481, y: 3)], displays: [builtIn], pointer: over, known: []).isEmpty)
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 1481, y: 3)], displays: [builtIn], pointer: over, known: [dot]) == [dot])
        let cursor = overlay(x: 1479, y: 1, w: 32, h: 32)
        #expect(RecordingIndicatorProvider.indicators(
            in: [cursor, overlay(x: 1481, y: 3)], displays: [builtIn], pointer: over, known: [dot])
            == [dot])
    }

    /// There is one cursor per snapshot. The arrow's window is 28×40, which
    /// the shape test rejects anyway, so with the arrow parked on the dot the
    /// square beside it is not the cursor: a recording started without
    /// moving the mouse off the clock is still seen at once.
    @Test func anArrowParkedOnTheDotHidesNothing() {
        let arrow = overlay(x: 1493, y: 6, w: 28, h: 40)
        let parked = CGPoint(x: 1500, y: 10)
        #expect(RecordingIndicatorProvider.indicators(
            in: [arrow, overlay(x: 1481, y: 3)], displays: [builtIn], pointer: parked, known: [])
            == [indicator(1, 1481, 3)])
        // In the built-in's top-left corner, beside the Sidecar's overhanging dot.
        let corner = overlay(x: 0, y: 0, w: 28, h: 40)
        #expect(RecordingIndicatorProvider.indicators(
            in: [corner] + live, displays: [builtIn, sidecar],
            pointer: CGPoint(x: 4, y: 3), known: []) == both)
        // A square cursor alone is still the cursor.
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 1484, y: -6, w: 32, h: 32)], displays: [builtIn],
            pointer: parked, known: []).isEmpty)
        // A wide overlay under the pointer is not a cursor and vouches for nothing.
        #expect(RecordingIndicatorProvider.indicators(
            in: [overlay(x: 1300, y: 0, w: 300, h: 32), overlay(x: 1484, y: -6, w: 32, h: 32)],
            displays: [builtIn], pointer: parked, known: []).isEmpty)
    }

    @Test func twoCandidatesOnOneDisplayTheRightmostThenTopmostWins() {
        let list = [overlay(x: 1400, y: 3), overlay(x: 1481, y: 9), overlay(x: 1481, y: 3)]
        for candidate in [list, Array(list.reversed())] {
            #expect(RecordingIndicatorProvider.indicators(in: candidate, displays: [builtIn])
                    == [indicator(1, 1481, 3)])
        }
    }

    @Test func appKitFramesFlipToTheWindowListSpace() {
        let flipped = RecordingIndicatorProvider.displayBounds(appKitFrames: [
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: -1103, y: 180, width: 1103, height: 802),
            CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        ])
        #expect(flipped == [
            CGRect(x: 0, y: 0, width: 1512, height: 982),
            CGRect(x: -1103, y: 0, width: 1103, height: 802),
            CGRect(x: 0, y: 982, width: 1920, height: 1080),
        ])
        #expect(RecordingIndicatorProvider.displayBounds(appKitFrames: []).isEmpty)
    }

    // MARK: - The payload

    /// With one display the scalars are what they always were.
    @Test func environmentOnOneDisplayIsWhatItWas() {
        #expect(RecordingIndicatorProvider.environment(for: [indicator(1, 1481, 3)]) == [
            "RECORDING": "on",
            "RECORDING_X": "1481",
            "RECORDING_Y": "3",
            "RECORDING_WIDTH": "28",
            "RECORDING_HEIGHT": "28",
            "RECORDING_DISPLAY": "1",
            "RECORDING_FRAMES": "1:1481,3,28,28",
        ])
    }

    @Test func environmentListsEveryDisplayAndLeadsWithTheLowest() {
        let two = RecordingIndicatorProvider.environment(for: both)
        #expect(two["RECORDING_FRAMES"] == "1:1481,3,28,28 2:1081,-6,28,28")
        #expect(two["RECORDING_DISPLAY"] == "1")
        #expect(two["RECORDING_X"] == "1481")

        let onlySidecar = RecordingIndicatorProvider.environment(for: [indicator(2, 1081, -6)])
        #expect(onlySidecar["RECORDING_FRAMES"] == "2:1081,-6,28,28")
        #expect(onlySidecar["RECORDING_DISPLAY"] == "2")
        #expect(onlySidecar["RECORDING_X"] == "1081")
        #expect(onlySidecar["RECORDING_Y"] == "-6")
    }

    @Test func offCarriesNoGeometry() {
        #expect(RecordingIndicatorProvider.environment(for: []) == ["RECORDING": "off"])
    }

    @Test func negativeZeroIsNeverPrinted() {
        let nearZero = RecordingIndicator(
            display: 1, frame: CGRect(x: -0.4, y: -0.0, width: 28, height: 28))
        #expect(RecordingIndicatorProvider.environment(for: [nearZero])["RECORDING_FRAMES"]
                == "1:0,0,28,28")
    }

    // MARK: - The provider

    @Test func theProviderSpeaksOnlyWhenTheAnswerChanges() {
        let provider = RecordingIndicatorProvider()
        var heard: [[RecordingIndicator]] = []
        provider.onChange = { heard.append($0) }

        provider.ingest(windows: live, displays: [builtIn, sidecar], pointer: nil)
        provider.ingest(windows: Array(live.reversed()), displays: [builtIn, sidecar], pointer: nil)
        #expect(heard == [both])

        // The Sidecar goes away: its window is on no display any more.
        provider.ingest(windows: live, displays: [builtIn], pointer: nil)
        #expect(heard == [both, [indicator(1, 1481, 3)]])

        provider.ingest(windows: [], displays: [builtIn], pointer: nil)
        #expect(heard == [both, [indicator(1, 1481, 3)], []])
    }

    /// A reload or a rebuilt bar asks for the answer again. It is said once
    /// more, and what was known is kept — or the pointer resting on the dot
    /// at that moment would report the recording as over.
    @Test func forgettingSaysItAgainOnceAndKeepsWhatItKnew() {
        let provider = RecordingIndicatorProvider()
        var heard: [[RecordingIndicator]] = []
        provider.onChange = { heard.append($0) }
        let list = [overlay(x: 1481, y: 3)]
        let onTheDot = CGPoint(x: 1495, y: 17)

        provider.ingest(windows: list, displays: [builtIn], pointer: nil)
        provider.forgetLastAnswer()
        provider.ingest(windows: list, displays: [builtIn], pointer: onTheDot)
        #expect(heard == [[indicator(1, 1481, 3)], [indicator(1, 1481, 3)]])

        provider.ingest(windows: list, displays: [builtIn], pointer: onTheDot)
        #expect(heard.count == 2)
    }

    /// A subscriber that arrives while nothing records still gets its answer.
    @Test func theFirstAnswerIsSaidEvenWhenItIsOff() {
        let provider = RecordingIndicatorProvider()
        var heard: [[RecordingIndicator]] = []
        provider.onChange = { heard.append($0) }
        provider.ingest(windows: [], displays: [builtIn], pointer: nil)
        provider.ingest(windows: [], displays: [builtIn], pointer: nil)
        #expect(heard == [[]])
    }
}
