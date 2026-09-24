import Foundation
import Testing
@testable import YBarKit

/// Where a quad lands on the device pixel grid. Every quad in every scene —
/// pill, bracket, text plate, popup panel, shadow, slider track, gauge, graph
/// bar and tick — is built from `pixelOrigin` and `pixelSize` on the same
/// rect, so what they agree on is what the bar looks like.
@MainActor
@Suite struct PixelGridTests {
    /// Rounding the origin and the EXTENT independently lets them disagree:
    /// `round(x·s) + round(w·s)` is not `round((x+w)·s)`. On a 61.37 pt pill
    /// slid 30 pt in 0.1 pt steps at 2x they disagreed on 60 of 301 steps, so
    /// a pill of constant width breathed by a pixel as it slid, and its right
    /// edge drifted off whatever was anchored to it.
    @Test func aQuadsFarEdgeLandsWhereTheNextQuadsNearEdgeDoes() {
        for step in 0...300 {
            let x = 10 + Double(step) * 0.1
            let rect = CGRect(x: x, y: 4.3, width: 61.37, height: 20.7)
            let origin = SceneBuilder.pixelOrigin(rect, scale: 2)
            let size = SceneBuilder.pixelSize(rect, scale: 2)
            let abutting = SceneBuilder.pixelOrigin(
                CGRect(x: rect.maxX, y: rect.maxY, width: 10, height: 10), scale: 2)
            #expect(origin.x + size.x == abutting.x)
            #expect(origin.y + size.y == abutting.y)
        }
    }

    /// Whole-pixel geometry is unaffected: the common case still rounds to
    /// exactly what it did.
    @Test func geometryAlreadyOnTheGridIsUnchanged() {
        let rect = CGRect(x: 12, y: 4, width: 60, height: 22)
        #expect(SceneBuilder.pixelOrigin(rect, scale: 2) == SIMD2<Float>(24, 8))
        #expect(SceneBuilder.pixelSize(rect, scale: 2) == SIMD2<Float>(120, 44))
        #expect(SceneBuilder.pixelSize(rect, scale: 1) == SIMD2<Float>(60, 22))
    }
}

/// Where TEXT lands on the grid. Static text snaps so stems stay even; text
/// that is scrolling does not, because on a 120 Hz panel the per-frame
/// advance is around two device pixels and snapping turns a constant speed
/// into a 2,2,3 stutter the eye reads as judder.
@MainActor
@Suite struct MarqueePlacementTests {
    private func marqueeItem() -> Item {
        let item = Item(name: "m", position: .left)
        item.label.string = "a title far too long for its slot"
        item.label.customWidth = 20
        item.scrollTexts = true
        return item
    }

    /// A scroll runs at a constant speed. Sampled at 120 Hz the advance is
    /// about two device pixels per frame, so snapping the pen to whole
    /// pixels quantized it to 2, 2, 3, 2, 2, 3: the speed changed several
    /// times a cycle, and the faster the panel the coarser that quantization
    /// was relative to the step. Unsnapped, every glyph advances equally.
    @Test func aScrollingLabelMovesAtAConstantSpeed() {
        let scene = HeadlessScene()
        let item = marqueeItem()
        let frame = 1.0 / 120.0

        var frames: [[Float]] = []
        for step in 0..<8 {
            scene.builder.clock = 1.0 + Double(step) * frame
            let glyphs = scene.build([item]).list.glyphs
            #expect(glyphs.count > 1)
            frames.append(glyphs.map(\.origin.x))
        }

        // Glyphs enter and leave the slot as the text wraps, so only compare
        // frames that carry the same run; the leftmost glyph is pinned by the
        // clip, so a zero delta is not a speed.
        var speeds: [Float] = []
        for (before, after) in zip(frames, frames.dropFirst()) where before.count == after.count {
            speeds.append(contentsOf: zip(before, after).map { $1 - $0 }.filter { $0 != 0 })
        }
        #expect(!speeds.isEmpty, "a scrolling label must move every frame")
        let spread = (speeds.max() ?? 0) - (speeds.min() ?? 0)
        // Whole-pixel snapping made this spread a full device pixel.
        #expect(spread < 0.01, "marquee speed varies by \(spread) px between frames")
        // The pen keeps its fractional part: that precision is the motion
        // rounding used to throw away.
        #expect(frames.flatMap { $0 }.contains { $0 != $0.rounded() })
    }

    /// Text that is not scrolling still lands on whole device pixels.
    @Test func staticTextStaysSnappedToTheGrid() {
        let scene = HeadlessScene()
        let item = Item(name: "s", position: .left)
        item.label.string = "Wi-Fi"

        let glyphs = scene.build([item]).list.glyphs
        #expect(!glyphs.isEmpty)
        for glyph in glyphs {
            // bearingPx is a whole number of device pixels, so a snapped pen
            // leaves the origin whole too.
            #expect(glyph.origin.x == glyph.origin.x.rounded())
        }
    }
}
