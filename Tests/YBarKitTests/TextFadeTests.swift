import Foundation
import Testing
@testable import YBarKit

/// Text that does not fit its fixed-width slot. Without `fade_width` it is
/// cut through whatever glyph straddles the edge; with it, the ink ramps out
/// over the last few points so the name reads as continuing rather than as
/// damaged — the popup rows that put a button beside a device name.
@MainActor
@Suite struct TextFadeTests {
    private func longName(fadeWidth: Float) -> Item {
        let item = Item(name: "row", position: .left)
        item.icon.string = "Yaroslava's AirPods Max"
        item.icon.customWidth = 60      // far narrower than the text
        item.icon.fadeWidth = fadeWidth
        item.label.drawing = false
        return item
    }

    @Test func overflowingTextFadesWhenAskedTo() {
        let scene = HeadlessScene()
        let glyphs = scene.build([longName(fadeWidth: 18)]).list.glyphs
        #expect(!glyphs.isEmpty)
        let faded = glyphs.filter { $0.flags & GlyphInstance.flagFade != 0 }
        #expect(faded.count == glyphs.count, "every glyph of the part carries the ramp")
        // The ramp ends at the slot edge and starts fade_width points before.
        let ramp = faded[0]
        #expect(ramp.fadeEnd > ramp.fadeStart)
        #expect((ramp.fadeEnd - ramp.fadeStart) == 18 * Float(scene.scale))
    }

    @Test func overflowingTextIsStillCutByDefault() {
        let scene = HeadlessScene()
        let glyphs = scene.build([longName(fadeWidth: 0)]).list.glyphs
        #expect(!glyphs.isEmpty)
        #expect(glyphs.allSatisfy { $0.flags & GlyphInstance.flagFade == 0 })
    }

    /// Text that fits is never faded, however wide the ramp is set.
    @Test func textThatFitsIsNotFaded() {
        let scene = HeadlessScene()
        let item = longName(fadeWidth: 18)
        item.icon.string = "TV"
        item.icon.customWidth = 200
        let glyphs = scene.build([item]).list.glyphs
        #expect(!glyphs.isEmpty)
        #expect(glyphs.allSatisfy { $0.flags & GlyphInstance.flagFade == 0 })
    }
}
