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

/// icon.shadow / label.shadow were parsed and stored but never drawn (review
/// finding A2): the glyphs must be emitted once more underneath, displaced by
/// (cos·d, −sin·d) in the shadow color, for ordinary text and SF symbols alike.
@MainActor
@Suite struct TextShadowTests {
    @Test func shadowOffsetIsAngleDistanceInDevicePixels() {
        var style = ShadowStyle()
        #expect(SceneBuilder.textShadow(style, scale: 2) == nil)
        style.drawing = true
        style.distance = 5
        style.angle = 30
        style.color = YColor(argb: 0x8000_0000)
        let shadow = SceneBuilder.textShadow(style, scale: 2)
        // cos30·5·2 ≈ 8.66 → 9 px right; sin30·5·2 = 5 px UP (y-down: −5).
        #expect(shadow?.offsetPx == SIMD2(9, -5))
        #expect(shadow?.color == YColor(argb: 0x8000_0000).simd)
    }

    @Test func labelShadowDoublesGlyphsUnderneath() {
        let scene = HeadlessScene()
        let item = Item(name: "t", position: .left)
        item.label.string = "Hi"
        item.label.shadow.drawing = true
        item.label.shadow.distance = 4
        item.label.shadow.angle = 90
        item.label.shadow.color = YColor(argb: 0xFF00_0000)
        let (list, _) = scene.build([item])
        // Two glyphs → two shadow copies first, then the ink.
        #expect(list.glyphs.count == 4)
        guard list.glyphs.count == 4 else { return }
        for index in 0..<2 {
            let shadow = list.glyphs[index]
            let ink = list.glyphs[index + 2]
            #expect(shadow.origin == ink.origin + SIMD2(0, -8))
            #expect(shadow.size == ink.size)
            #expect(shadow.uvOrigin == ink.uvOrigin)
            #expect(shadow.color == YColor(argb: 0xFF00_0000).simd)
            #expect(ink.color == item.label.color.simd)
        }
    }

    @Test func symbolIconShadowIsEmittedToo() {
        let scene = HeadlessScene()
        let item = Item(name: "t", position: .left)
        item.icon.string = "sf:wifi"
        item.icon.shadow.drawing = true
        item.icon.shadow.distance = 2
        item.icon.shadow.angle = 0
        let (list, _) = scene.build([item])
        #expect(list.glyphs.count == 2)
        guard list.glyphs.count == 2 else { return }
        #expect(list.glyphs[0].origin == list.glyphs[1].origin + SIMD2(4, 0))
        #expect(list.glyphs[0].color == item.icon.shadow.color.simd)
    }

    @Test func queryReportsTextShadow() {
        var part = TextPart()
        part.shadow.drawing = true
        part.shadow.distance = 3
        part.shadow.angle = 45
        let shadow = Serialize.textDictionary(part)["shadow"] as? [String: Any]
        #expect(shadow?["drawing"] as? String == "on")
        #expect(shadow?["distance"] as? Float == 3)
        #expect(shadow?["angle"] as? Float == 45)
        #expect(shadow?["color"] as? String == "0xff000000")
    }
}

/// The marquee flag rides on each scene's DisplayList (review finding A1):
/// the frame clock was armed from a per-builder flag that the last surface
/// to render overwrote, and popup scenes never reported at all.
@MainActor
@Suite struct MarqueeDemandTests {
    private func marqueeItem(position: ItemPosition) -> Item {
        let item = Item(name: "m", position: position)
        item.label.string = "a title far too long for its slot"
        item.label.customWidth = 20
        item.scrollTexts = true
        return item
    }

    @Test func barSceneFlagsOverflowingMarquee() {
        let scene = HeadlessScene()
        #expect(scene.build([marqueeItem(position: .left)]).list.hasMarquee)
        let plain = Item(name: "p", position: .left)
        plain.label.string = "x"
        #expect(!scene.build([plain]).list.hasMarquee)
    }

    @Test func popupSceneCarriesItsOwnFlag() {
        let scene = HeadlessScene()
        let host = Item(name: "host", position: .left)
        let member = marqueeItem(position: .popup)
        member.popupHost = host.name
        let popup = scene.builder.buildPopup(
            host: host, members: [member], scale: scene.scale, atlas: scene.atlas)
        #expect(popup.hasMarquee)

        // Per scene, not per builder: neither a plain popup nor a plain bar
        // scene built afterwards inherits the flag.
        let plain = Item(name: "p", position: .popup)
        plain.popupHost = host.name
        plain.label.string = "x"
        let plainPopup = scene.builder.buildPopup(
            host: host, members: [plain], scale: scene.scale, atlas: scene.atlas)
        #expect(!plainPopup.hasMarquee)
        let bar = Item(name: "b", position: .left)
        bar.label.string = "x"
        #expect(!scene.build([bar]).list.hasMarquee)
    }
}

/// A graph on a bordered plate runs inside the frame (review finding A3):
/// the box is inset by the border width, and the stroke never leaves it.
@MainActor
@Suite struct GraphPlateTests {
    private func graphItem(borderWidth: Float) -> Item {
        let item = Item(name: "g", position: .left)
        item.kind = .graph
        let graph = GraphState(capacity: 40)
        for sample in [0, 1, 0.5, 0, 1] as [Float] { graph.push(sample) }
        item.graph = graph
        item.background.drawing = true
        item.background.height = 20
        item.background.borderWidth = borderWidth
        return item
    }

    @Test func borderInsetsTheGraphBox() {
        let scene = HeadlessScene(scale: 1)
        let item = graphItem(borderWidth: 3)
        let (list, boxes) = scene.build([item])
        guard let box = boxes[item.id] else {
            Issue.record("graph item was not laid out")
            return
        }
        let xs = list.triangles.map(\.position.x)
        let ys = list.triangles.map(\.position.y)
        #expect(!xs.isEmpty)
        // Plate is 40 wide, 20 tall, centred on the content box; the graph
        // keeps 3pt clear of the frame on every side. Sample columns land
        // exactly on the inset edges; a sloped stroke's end cap may overhang
        // them sideways by up to half a line width (unclamped in x).
        let cap = Float(item.graph!.lineWidth) / 2
        #expect(xs.contains(Float(box.minX + 3)))
        #expect(xs.contains(Float(box.minX + 40 - 3)))
        #expect(xs.allSatisfy { $0 >= Float(box.minX + 3) - cap && $0 <= Float(box.minX + 40 - 3) + cap })
        #expect(ys.min() == Float(box.midY - 10 + 3))
        #expect(ys.max() == Float(box.midY + 10 - 3))
    }

    @Test func noBorderMeansNoInset() {
        let scene = HeadlessScene(scale: 1)
        let item = graphItem(borderWidth: 0)
        let (list, boxes) = scene.build([item])
        guard let box = boxes[item.id] else {
            Issue.record("graph item was not laid out")
            return
        }
        let xs = list.triangles.map(\.position.x)
        let ys = list.triangles.map(\.position.y)
        #expect(xs.contains(Float(box.minX)))
        #expect(xs.contains(Float(box.minX + 40)))
        #expect(ys.min() == Float(box.midY - 10))
        #expect(ys.max() == Float(box.midY + 10))
    }
}

/// background.padding_left/right were parsed and published by --query but
/// never applied (review finding A7): they widen the pill beyond the content
/// box. The clip hole and the glass backdrop share backgroundRect, so they
/// follow for free; the hit frame stays the content width.
@MainActor
@Suite struct BackgroundPaddingTests {
    @Test func paddingWidensThePillAroundTheContentBox() {
        let item = Item(name: "b", position: .left)
        item.background.paddingLeft = 6
        item.background.paddingRight = 4
        item.background.xOffset = 1
        let contentBox = CGRect(x: 100, y: 0, width: 50, height: 32)
        let rect = SceneBuilder.backgroundRect(item: item, contentBox: contentBox, contentHeight: 14)
        #expect(rect.minX == 95)
        #expect(rect.width == 60)
        #expect(rect.height == 22)
        #expect(rect.midY == contentBox.midY)
    }

    @Test func paddedPillIsWhatGetsPainted() {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "b", position: .left)
        item.label.string = "x"
        item.background.drawing = true
        item.background.paddingLeft = 6
        item.background.paddingRight = 4
        let (list, boxes) = scene.build([item])
        guard let box = boxes[item.id] else {
            Issue.record("item was not laid out")
            return
        }
        // quads[0] is the bar background; the pill follows it.
        #expect(list.quads.count >= 2)
        guard list.quads.count >= 2 else { return }
        let pill = list.quads[1]
        #expect(pill.origin.x == Float(box.minX - 6))
        #expect(pill.size.x == Float(box.width + 10))
        // The interactive frame is unchanged by the pill's padding.
        #expect(item.frame.minX == box.minX)
        #expect(item.frame.width == box.width)
    }
}

/// Image and SF-symbol atlas keys bucket their size like glyph keys do
/// (review finding A10): the shelf packer never reclaims, so an animated
/// size must not mint a cell per interpolation frame.
@Suite struct AtlasKeyTests {
    @Test func sizesShareAQuarterPointBucket() {
        #expect(GlyphAtlas.quarterPoint(18.1) == 18)
        #expect(GlyphAtlas.quarterPoint(18.13) == 18.25)
        #expect(GlyphAtlas.quarterPoint(18.4) == 18.5)
    }

    @Test func imageKeysBucketSizeAndRoundRotation() {
        let steady = SceneBuilder.imageCacheKey(source: "app.Finder", size: 18.05, rotation: 0)
        #expect(SceneBuilder.imageCacheKey(source: "app.Finder", size: 18.1, rotation: 0) == steady)
        #expect(SceneBuilder.imageCacheKey(source: "app.Finder", size: 18.5, rotation: 0) != steady)
        // Rotation stays per degree.
        #expect(SceneBuilder.imageCacheKey(source: "sf.arrow", size: 18, rotation: 12.4)
                == SceneBuilder.imageCacheKey(source: "sf.arrow", size: 18, rotation: 11.6))
        #expect(SceneBuilder.imageCacheKey(source: "sf.arrow", size: 18, rotation: 12.6)
                != SceneBuilder.imageCacheKey(source: "sf.arrow", size: 18, rotation: 12.4))
    }

    @Test func symbolKeysBucketSize() {
        let steady = SceneBuilder.symbolCacheKey(name: "wifi", size: 14)
        #expect(SceneBuilder.symbolCacheKey(name: "wifi", size: 14.1) == steady)
        #expect(SceneBuilder.symbolCacheKey(name: "wifi", size: 14.25) != steady)
        #expect(SceneBuilder.symbolCacheKey(name: "wifi.slash", size: 14) != steady)
    }
}

/// The slider knob is a single glyph and centres its ink on the track like
/// an icon does (review finding E12); em-box centring only looked right
/// because SF's circle happens to be symmetric about the em centre.
@MainActor
@Suite struct SliderKnobTests {
    @Test func knobInkIsCentredOnTheTrack() {
        let scene = HeadlessScene()
        let item = Item(name: "s", position: .left)
        item.kind = .slider
        let slider = SliderState(width: 100)
        slider.percentage = 50
        // An apostrophe's ink sits far above the em centre: em-centring
        // would place it ~3.5pt (7px here) too high.
        slider.knob.string = "'"
        item.slider = slider
        let (list, boxes) = scene.build([item])
        #expect(list.glyphs.count == 1)
        guard let box = boxes[item.id], let knob = list.glyphs.first else {
            Issue.record("slider was not laid out or drew no knob")
            return
        }
        let knobCenterY = knob.origin.y + knob.size.y / 2
        #expect(abs(knobCenterY - Float(box.midY * scene.scale)) <= 2)
    }
}
