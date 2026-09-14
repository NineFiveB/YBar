import AppKit
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

    /// The colour atlas page is sampled as-is (only the instance alpha is
    /// honoured), so a shadow copy of an emoji would be a second opaque emoji
    /// rather than a silhouette: colour glyphs get no shadow (finding GPU3).
    @Test func colourGlyphsGetNoShadowCopy() {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "t", position: .left)
        item.label.string = "a🔋"
        item.label.shadow.drawing = true
        item.label.shadow.distance = 4
        item.label.shadow.angle = 90
        let (list, _) = scene.build([item])
        let colour = list.glyphs.filter { $0.flags & GlyphInstance.flagColorGlyph != 0 }
        // The emoji really is on the colour page; the "a" really is not.
        #expect(colour.count == 1)
        // One shadow for the "a", then both inks — no fourth quad.
        #expect(list.glyphs.count == 3)
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
    private func graphItem(borderWidth: Float, borderAlpha: Float = 1) -> Item {
        let item = Item(name: "g", position: .left)
        item.kind = .graph
        let graph = GraphState(capacity: 40)
        for sample in [0, 1, 0.5, 0, 1] as [Float] { graph.push(sample) }
        item.graph = graph
        item.background.drawing = true
        item.background.height = 20
        item.background.borderWidth = borderWidth
        item.background.borderColor = YColor(alpha: borderAlpha, red: 1, green: 1, blue: 1)
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

    /// border_width is inherited from the --default prototype and switched
    /// off by a transparent border_color (examples/sketchybar-port's graphs),
    /// so only a border that paints may shrink the graph (finding GPU2).
    @Test func invisibleBorderMeansNoInset() {
        let scene = HeadlessScene(scale: 1)
        let item = graphItem(borderWidth: 3, borderAlpha: 0)
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

    /// A border wider than the plate must not turn the box inside out.
    @Test func hugeBorderCannotInvertTheBox() {
        let scene = HeadlessScene(scale: 1)
        let item = graphItem(borderWidth: 40)
        let (list, boxes) = scene.build([item])
        guard let box = boxes[item.id] else {
            Issue.record("graph item was not laid out")
            return
        }
        let xs = list.triangles.map(\.position.x)
        let ys = list.triangles.map(\.position.y)
        // Collapsed to the centre line at worst — never mirrored.
        #expect(xs.allSatisfy { $0 >= Float(box.minX) && $0 <= Float(box.minX + 40) })
        #expect(ys.allSatisfy { $0 >= Float(box.midY - 10) && $0 <= Float(box.midY + 10) })
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

/// The drag hit-mapping and the renderer once computed a slider's track
/// origin separately and disagreed (review finding A8): the hit side clamped
/// the alignment slack, skipped the paddings of an empty icon and knew
/// nothing of a leading image. SceneBuilder.sliderTrackX now serves both;
/// these pin the painted track to it and a press at its midpoint to 50%.
@MainActor
@Suite(.serialized) struct SliderTrackTests {
    private let trackWidth: Float = 80

    private func headlessManager() throws -> BarManager {
        let manager = try BarManager()
        manager.settings.displayPolicy = .list([])
        return manager
    }

    private func press(x: CGFloat) -> MouseEventInfo {
        MouseEventInfo(kind: .down, point: CGPoint(x: x, y: 10), button: "left",
                       modifier: "none", scrollDelta: 0)
    }

    /// The slider lives in the manager's store (the press path resolves it
    /// there) and is laid out by the headless scene, which writes the frame
    /// the surfaces snapshot. Returns the helper's track x, the painted
    /// track's device x (the one quad exactly trackWidth wide) and the
    /// content box.
    private func addSlider(to manager: BarManager, scene: HeadlessScene,
                           configure: (Item) -> Void)
        throws -> (item: Item, trackX: CGFloat, paintedX: Float?, box: CGRect) {
        let item = try #require(manager.store.add(name: "seek", position: .left))
        item.kind = .slider
        item.slider = SliderState(width: trackWidth)
        configure(item)
        let (list, boxes) = scene.build([item])
        let box = try #require(boxes[item.id])
        let trackX = SceneBuilder.sliderTrackX(item: item, contentBox: box, measured: scene.measure(item))
        let painted = list.quads.first { $0.size.x == trackWidth * Float(scene.scale) }?.origin.x
        return (item, trackX, painted, box)
    }

    @Test func centredOverflowUsesTheUnclampedSlack() throws {
        let scene = HeadlessScene()
        let manager = try headlessManager()
        let (item, trackX, painted, box) = try addSlider(to: manager, scene: scene) { item in
            item.icon.paddingLeft = 8
            item.icon.paddingRight = 8
            item.customWidth = 60      // natural is 16 + 80 = 96: overflow
            item.align = "c"
        }
        // -36 of slack split evenly, then the empty icon's 16pt of paddings.
        #expect(trackX == box.minX - 2)
        #expect(painted == Float((trackX * scene.scale).rounded()))

        let popup = PopupSurface(hostItemID: -1, device: manager.device)
        popup.itemFrames = [(item.id, item.frame)]
        manager.handlePopupMouse(press(x: trackX + CGFloat(trackWidth) / 2), on: popup)
        #expect(abs((item.slider?.percentage ?? 0) - 50) < 0.01)
    }

    @Test func emptyIconPaddingsAdvanceTheTrack() throws {
        let scene = HeadlessScene()
        let manager = try headlessManager()
        let (item, trackX, painted, box) = try addSlider(to: manager, scene: scene) { item in
            item.icon.paddingLeft = 8
            item.icon.paddingRight = 8
        }
        #expect(trackX == box.minX + 16)
        #expect(painted == Float((trackX * scene.scale).rounded()))

        // The bar surface takes the same path as the popup one.
        let screen = try #require(NSScreen.screens.first)
        let surface = BarSurface(screen: screen, arrangementIndex: 1)
        surface.itemFrames = [(item.id, item.frame)]
        manager.handleMouse(press(x: trackX + CGFloat(trackWidth) / 2), on: surface)
        #expect(abs((item.slider?.percentage ?? 0) - 50) < 0.01)
    }

    @Test func leadingImageAdvancesTheTrack() throws {
        let scene = HeadlessScene()
        let manager = try headlessManager()
        let (item, trackX, painted, box) = try addSlider(to: manager, scene: scene) { item in
            let image = ImageState()
            image.source = "sf.circle"
            image.size = 18
            image.paddingLeft = 2
            image.paddingRight = 2
            item.image = image
        }
        #expect(trackX == box.minX + 22)
        #expect(painted == Float((trackX * scene.scale).rounded()))

        let popup = PopupSurface(hostItemID: -1, device: manager.device)
        popup.itemFrames = [(item.id, item.frame)]
        manager.handlePopupMouse(press(x: trackX + CGFloat(trackWidth) / 2), on: popup)
        #expect(abs((item.slider?.percentage ?? 0) - 50) < 0.01)
    }
}

/// `image.desaturate` and `image.y_offset` (review finding A11): the grey
/// path is a glyph flag the shader honours on the colour page (no atlas-key
/// dimension), and the offset moves the image up like every other y_offset.
@MainActor
@Suite struct ImageStyleTests {
    private func imageItem(name: String, yOffset: Float, desaturate: Bool) -> Item {
        let item = Item(name: name, position: .left)
        let image = ImageState()
        image.source = "sf.circle"
        image.size = 18
        image.yOffset = yOffset
        image.desaturate = desaturate
        item.image = image
        return item
    }

    @Test func desaturateSetsTheGreyFlagAndYOffsetLiftsTheImage() throws {
        let scene = HeadlessScene(scale: 2)
        let plain = imageItem(name: "a", yOffset: 0, desaturate: false)
        let styled = imageItem(name: "b", yOffset: 3, desaturate: true)
        let (list, _) = scene.build([plain, styled])
        #expect(list.glyphs.count == 2)
        let first = try #require(list.glyphs.first)
        let second = try #require(list.glyphs.last)
        #expect(first.flags == GlyphInstance.flagColorGlyph)
        #expect(second.flags == GlyphInstance.flagColorGlyph | GlyphInstance.flagDesaturate)
        // 3pt up at 2x: 6px less y (y-down).
        #expect(second.origin.y == first.origin.y - 6)
        #expect(second.size == first.size)
    }

    @Test func queryReportsBoth() {
        let item = Item(name: "t", position: .left)
        let image = ImageState()
        image.source = "sf.circle"
        image.yOffset = 2
        image.desaturate = true
        item.image = image
        let dictionary = Serialize.itemDictionary(item)["image"] as? [String: Any]
        #expect(dictionary?["y_offset"] as? Float == 2)
        #expect(dictionary?["desaturate"] as? String == "on")
    }
}

/// `background.shadow.blur` (review finding A5): above 0 the shadow quad is
/// grown by the blur on every side, the true half size rides in fill2.xy,
/// the blur in gradientDir.x and flag bit 4 selects the shader's squared
/// smoothstep falloff — the Windows port's instance ABI, bit for bit. Zero
/// keeps sketchybar's hard offset copy.
@MainActor
@Suite struct SoftShadowTests {
    private func shadowed(_ item: Item, blur: Float, distance: Float) {
        item.label.string = "Hi"
        item.background.drawing = true
        item.background.color = YColor(argb: 0xFF22_2222)
        item.background.shadow.drawing = true
        item.background.shadow.color = YColor(argb: 0x8000_0000)
        item.background.shadow.distance = distance
        item.background.shadow.angle = 0
        item.background.shadow.blur = blur
    }

    @Test func blurGrowsTheQuadAndStashesTheTrueHalfSize() throws {
        let scene = HeadlessScene(scale: 2)
        let item = Item(name: "t", position: .left)
        shadowed(item, blur: 3, distance: 0)
        let (list, _) = scene.build([item])
        // Bar background, shadow, then the plate.
        #expect(list.quads.count == 3)
        let shadow = try #require(list.quads.dropFirst().first)
        let plate = try #require(list.quads.last)
        #expect(shadow.flags & QuadInstance.flagShadow != 0)
        #expect(shadow.fill == YColor(argb: 0x8000_0000).simd)
        // 3pt at 2x = 6px of growth per side; fill2 holds the ungrown half size.
        #expect(shadow.fill2 == SIMD4(plate.size.x / 2, plate.size.y / 2, 0, 0))
        #expect(shadow.origin == plate.origin - SIMD2(6, 6))
        #expect(shadow.size == plate.size + SIMD2(12, 12))
        #expect(shadow.gradientDir == SIMD2(6, 0))
        #expect(shadow.radii == plate.radii)
    }

    @Test func zeroBlurKeepsTheHardOffsetCopy() throws {
        let scene = HeadlessScene(scale: 2)
        let item = Item(name: "t", position: .left)
        shadowed(item, blur: 0, distance: 4)
        let (list, _) = scene.build([item])
        let shadow = try #require(list.quads.dropFirst().first)
        let plate = try #require(list.quads.last)
        #expect(shadow.flags & QuadInstance.flagShadow == 0)
        #expect(shadow.origin == plate.origin + SIMD2(8, 0))
        #expect(shadow.size == plate.size)
        #expect(shadow.fill2 == .zero)
    }

    @Test func bracketsGetTheSoftShadowToo() throws {
        let scene = HeadlessScene(scale: 2)
        let member = Item(name: "a", position: .left)
        member.label.string = "Hi"
        let bracket = Item(name: "b", position: .left)
        bracket.kind = .bracket
        bracket.members = ["a"]
        shadowed(bracket, blur: 2, distance: 0)
        bracket.label.string = ""
        let (list, _) = scene.build([member, bracket])
        // Bar background, bracket shadow, bracket plate; the member has none.
        #expect(list.quads.count == 3)
        let shadow = try #require(list.quads.dropFirst().first)
        let plate = try #require(list.quads.last)
        #expect(shadow.flags & QuadInstance.flagShadow != 0)
        #expect(shadow.size == plate.size + SIMD2(8, 8))
    }

    @Test func queryReportsTheBlur() {
        var shadow = ShadowStyle()
        shadow.blur = 2.5
        #expect(Serialize.shadowDictionary(shadow)["blur"] as? Float == 2.5)
    }
}

/// icon.background.* / label.background.* were parsed, published by --query
/// and never drawn (review finding A4). Each drawing part now emits one
/// plate around its ink — natural measure plus the plate's own paddings,
/// centred on the item's centre line — without widening the layout.
@MainActor
@Suite struct PartBackgroundTests {
    private func plated(_ part: inout TextPart) {
        part.background.drawing = true
        part.background.color = YColor(argb: 0xFF11_2233)
        part.background.paddingLeft = 3
        part.background.paddingRight = 5
    }

    @Test func labelPlateIsOneQuadAroundTheInk() throws {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "t", position: .left)
        item.label.string = "Hi"
        item.label.paddingLeft = 4
        plated(&item.label)
        let (list, boxes) = scene.build([item])
        let box = try #require(boxes[item.id])
        let ink = scene.fontCache.naturalMeasure(part: item.label)
        // The layout is untouched: the plate paddings live outside it.
        #expect(box.width == 4 + ink.width)
        // Bar background, then exactly one plate; the ink still draws.
        #expect(list.quads.count == 2)
        #expect(list.glyphs.count == 2)
        let plate = try #require(list.quads.last)
        #expect(plate.fill == YColor(argb: 0xFF11_2233).simd)
        #expect(plate.origin.x == Float((box.minX + 4 - 3).rounded()))
        #expect(plate.size.x == Float((ink.width + 3 + 5).rounded()))
        #expect(plate.size.y == Float((ink.height + 4).rounded()))
        #expect(plate.origin.y == Float((box.midY - (ink.height + 4) / 2).rounded()))
    }

    @Test func symbolIconGetsAPlateToo() throws {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "t", position: .left)
        item.icon.string = "sf:wifi"
        plated(&item.icon)
        item.icon.background.height = 20
        let (list, boxes) = scene.build([item])
        let box = try #require(boxes[item.id])
        let ink = scene.fontCache.naturalMeasure(part: item.icon)
        #expect(list.quads.count == 2)
        let plate = try #require(list.quads.last)
        #expect(plate.origin.x == Float((box.minX - 3).rounded()))
        #expect(plate.size.x == Float((ink.width + 8).rounded()))
        #expect(plate.size.y == 20)
    }

    @Test func fixedWidthPartPlateFollowsTheSlotAlignment() throws {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "t", position: .left)
        item.label.string = "Hi"
        item.label.customWidth = 100
        item.label.align = "r"
        plated(&item.label)
        let (list, boxes) = scene.build([item])
        let box = try #require(boxes[item.id])
        let ink = scene.fontCache.naturalMeasure(part: item.label)
        #expect(box.width == 100)
        let plate = try #require(list.quads.last)
        // Right-aligned in the slot: the ink starts at slot end minus ink.
        #expect(plate.origin.x == Float((box.minX + 100 - ink.width - 3).rounded()))
    }

    /// The plate is sized from the NATURAL ink, so it can overflow the slot
    /// the glyphs are clipped to; it must be trimmed by the same clip rather
    /// than painting over the neighbours (review finding GPU1).
    @Test func plateIsTrimmedToANarrowSlot() throws {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "t", position: .left)
        item.label.string = "Hello world"
        item.label.customWidth = 20
        plated(&item.label)
        let (list, boxes) = scene.build([item])
        let box = try #require(boxes[item.id])
        #expect(scene.fontCache.naturalMeasure(part: item.label).width > 20)
        let plate = try #require(list.quads.last)
        // The plate starts 3pt (its own left padding) before the slot and is
        // ink-wide: both ends are cut back to the slot.
        #expect(plate.origin.x == Float(box.minX))
        #expect(plate.origin.x + plate.size.x == Float(box.minX + 20))
    }

    /// A collapsed item (width=0, every --animate width frame under the
    /// natural content) clips its glyphs away; the plate must go with them.
    @Test func collapsedItemDrawsNoPlate() {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "t", position: .left)
        item.label.string = "Hello world"
        item.customWidth = 0
        plated(&item.label)
        let (list, _) = scene.build([item])
        // Bar background only — no ink, and no plate behind the missing ink.
        #expect(list.quads.count == 1)
        #expect(list.glyphs.isEmpty)
    }

    @Test func nothingIsDrawnWhenTheStyleIsOff() {
        let scene = HeadlessScene(scale: 1)
        let item = Item(name: "t", position: .left)
        item.label.string = "Hi"
        item.label.background.color = YColor(argb: 0xFF11_2233)
        item.label.background.drawing = false
        let (list, _) = scene.build([item])
        #expect(list.quads.count == 1)
    }
}

/// `slider.interactive=off` turns a slider into a read-only meter (review
/// finding B1): a press must not enter the drag machinery or rewrite the
/// percentage from the pointer, and the release is an ordinary click — on
/// the bar and inside a popup alike.
@MainActor
@Suite(.serialized) struct ReadOnlySliderTests {
    private let slot = CGRect(x: 0, y: 0, width: 100, height: 25)

    private func headlessManager() throws -> BarManager {
        let manager = try BarManager()
        manager.settings.displayPolicy = .list([])
        return manager
    }

    private func mouse(_ kind: MouseEventKind, x: CGFloat = 50) -> MouseEventInfo {
        MouseEventInfo(kind: kind, point: CGPoint(x: x, y: 10), button: "left",
                       modifier: "none", scrollDelta: 0)
    }

    private func addMeter(to manager: BarManager) throws -> Item {
        let item = try #require(manager.store.add(name: "battery", position: .left))
        item.kind = .slider
        let slider = SliderState(width: 80)
        slider.percentage = 30
        slider.interactive = false
        item.slider = slider
        return item
    }

    @Test func barPressOnAReadOnlySliderIsAClick() throws {
        let manager = try headlessManager()
        let item = try addMeter(to: manager)
        let screen = try #require(NSScreen.screens.first)
        let surface = BarSurface(screen: screen, arrangementIndex: 1)
        surface.itemFrames = [(item.id, slot)]
        var clicked: [String] = []
        var dragStarted = 0
        manager.onItemClicked = { item, _ in clicked.append(item.name) }
        manager.onSliderDragStarted = { _ in dragStarted += 1 }

        manager.handleMouse(mouse(.down), on: surface)
        #expect(manager.draggingSliderID == nil)
        #expect(dragStarted == 0)
        #expect(item.slider?.percentage == 30)
        manager.handleMouse(mouse(.dragged, x: 70), on: surface)
        #expect(item.slider?.percentage == 30)
        manager.handleMouse(mouse(.clicked), on: surface)
        #expect(clicked == ["battery"])

        // Back to interactive: the same press scrubs again.
        item.slider?.interactive = true
        manager.handleMouse(mouse(.down, x: 40), on: surface)
        #expect(manager.draggingSliderID == item.id)
        #expect(item.slider?.percentage == 50)
    }

    @Test func popupPressOnAReadOnlySliderIsAClick() throws {
        let manager = try headlessManager()
        let item = try addMeter(to: manager)
        let popup = PopupSurface(hostItemID: -1, device: manager.device)
        popup.itemFrames = [(item.id, slot)]
        var clicked: [String] = []
        manager.onItemClicked = { item, _ in clicked.append(item.name) }

        manager.handlePopupMouse(mouse(.down), on: popup)
        #expect(manager.draggingSliderID == nil)
        #expect(item.slider?.percentage == 30)
        manager.handlePopupMouse(mouse(.clicked), on: popup)
        #expect(clicked == ["battery"])
    }
}

/// A bar with no frame (`--bar height=0`, or a margin at least half the
/// screen wide) is a config state, not a transient: nothing but a geometry
/// change can clear it, and every path that changes bar geometry already ends
/// in setNeedsRender(). The guard must report once and stop, not leave a 1 s
/// retry re-arming itself forever on an otherwise idle daemon (LIFETIME-1).
@MainActor
@Suite(.serialized) struct EmptyBarFrameTests {
    @Test func anEmptyBarFrameIsNotPolledFor() throws {
        let manager = try BarManager()
        // An empty display list keeps the manager from building real panels.
        manager.settings.displayPolicy = .list([])
        let screen = try #require(NSScreen.screens.first)
        let surface = BarSurface(screen: screen, arrangementIndex: 1)
        var settings = BarSettings()
        settings.height = 0
        // hidden keeps the (zero-height) panel out of the window list; the
        // frame is applied either way.
        settings.hidden = true
        surface.apply(settings: settings, screen: screen)

        #expect(surface.barSize.height == 0)
        #expect(!manager.render(surface: surface))
        #expect(!manager.retryScheduled)
    }
}
