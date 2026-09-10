import Foundation
import simd
import Testing
@testable import YBarKit

/// Scene-level regression tests: whole bar and popup scenes built through the
/// real SceneBuilder on a textureless GlyphAtlas, so glyph placement can be
/// asserted without a Metal device.

@MainActor
struct HeadlessScene {
    let fontCache = FontCache()
    let builder: SceneBuilder
    let atlas: GlyphAtlas
    let scale: CGFloat
    let settings = BarSettings()
    let barSize = CGSize(width: 400, height: 32)

    init(scale: CGFloat = 2) {
        self.scale = scale
        builder = SceneBuilder(fontCache: fontCache)
        atlas = GlyphAtlas(scale: scale)
    }

    func measure(_ item: Item) -> MeasuredContent {
        MeasuredContent(iconSize: fontCache.measure(part: item.icon),
                        labelSize: fontCache.measure(part: item.label))
    }

    /// Lays the items out and builds the bar scene, like BarManager.render.
    func build(_ items: [Item]) -> (list: DisplayList, contentBoxes: [Int: CGRect]) {
        let result = Layout.perform(items: items, barSize: barSize, settings: settings, measure: measure)
        let list = builder.build(items: items, settings: settings, contentBoxes: result.contentBoxes,
                                 barSize: barSize, scale: scale, atlas: atlas)
        return (list, result.contentBoxes)
    }
}

@MainActor
@Suite struct HeadlessAtlasTests {
    @Test func texturelessAtlasStillHandsOutEntries() {
        let scene = HeadlessScene()
        let item = Item(name: "t", position: .left)
        item.label.string = "Hi"
        let (list, _) = scene.build([item])
        #expect(list.glyphs.count == 2)
        #expect(list.glyphs.allSatisfy { $0.size.x > 0 && $0.size.y > 0 })
        #expect(scene.atlas.maskTexture == nil)
    }
}
