import CoreGraphics
import Foundation
import Testing
@testable import YBarKit

/// The screen-recording indicator is found in the window list by what the
/// list gives without a grant — owner, layer, bounds — never by name, which
/// comes back empty without Screen Recording. These pin that matcher against
/// what the list actually looks like, so a change to the shape of the
/// heuristic has to be deliberate.
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

    /// Measured on macOS 27 while `screencapture -v` ran.
    @Test func findsTheIndicatorAsMeasured() {
        let list = [
            window(owner: "MenuBarAgent", layer: 25, x: 0, y: 0, w: 1512, h: 33),
            window(owner: "Window Server", layer: 2_147_483_630, x: 1481, y: 3, w: 28, h: 28),
            window(owner: "YBar", layer: 26, x: 0, y: 0, w: 1512, h: 40),
        ]
        #expect(RecordingIndicatorProvider.indicatorFrame(in: list)
                == CGRect(x: 1481, y: 3, width: 28, height: 28))
    }

    @Test func nothingWhenNoRecordingRuns() {
        let list = [
            window(owner: "MenuBarAgent", layer: 25, x: 0, y: 0, w: 1512, h: 33),
            window(owner: "YBar", layer: 26, x: 0, y: 0, w: 1512, h: 40),
        ]
        #expect(RecordingIndicatorProvider.indicatorFrame(in: list) == nil)
    }

    /// The WindowServer owns other overlays (the whole bar strip at layer 25,
    /// the cursor, a wide notch cover). None of them is a small square at a
    /// far-above-app layer, and none may count.
    @Test func otherWindowServerWindowsDoNotCount() {
        let list = [
            window(owner: "Window Server", layer: 25, x: 0, y: 0, w: 1512, h: 33),
            window(owner: "Window Server", layer: 2_147_483_630, x: 600, y: 0, w: 300, h: 32),
            window(owner: "Window Server", layer: 2_147_483_630, x: 1481, y: 400, w: 28, h: 28),
            window(owner: "SomeApp", layer: 2_147_483_630, x: 1481, y: 3, w: 28, h: 28),
        ]
        #expect(RecordingIndicatorProvider.indicatorFrame(in: list) == nil)
    }

    @Test func theEventIsBuiltIn() {
        #expect(EventBus.builtinEvents.contains("recording_change"))
    }
}
