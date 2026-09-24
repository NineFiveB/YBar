import AppKit
import CoreText
import simd

/// Traverses the item tree + layout result into a flat, paint-ordered DisplayList
/// in device pixels. Paint order: bar background → bracket backgrounds (behind
/// members) → per item (shadow, background, icon, sandwich content, label).
/// Re-encoding the full bar every dirty frame is microseconds; damage tracking
/// gates *whether* a frame renders, never what is drawn.
@MainActor
public final class SceneBuilder {
    let fontCache: FontCache
    /// Atlas of the scene being built (set on build entry; used by nested
    /// emitters like background images).
    private var activeAtlas: GlyphAtlas?
    /// Monotonic clock driving marquee phase (set by the render loop).
    public var clock: CFTimeInterval = 0
    /// Cursor in the surface being built, pixels, top-left y-down.
    public var pointer = SIMD2<Float>(repeating: -1e6)

    public init(fontCache: FontCache) {
        self.fontCache = fontCache
    }

    // MARK: - Bar scene

    public func build(
        items: [Item],
        settings: BarSettings,
        contentBoxes: [Int: CGRect],
        barSize: CGSize,
        scale: CGFloat,
        atlas: GlyphAtlas
    ) -> DisplayList {
        var list = DisplayList()
        activeAtlas = atlas

        // Bar background (drawn over the optional system-blur material).
        let barRadius = Float(settings.cornerRadius) * Float(scale)
        var barQuad = QuadInstance(
            origin: SIMD2(0, 0),
            size: SIMD2(Float(barSize.width * scale), Float(barSize.height * scale)),
            radii: SIMD4(repeating: barRadius),
            fill: settings.backgroundColor.simd,
            borderWidth: Float(settings.borderWidth) * Float(scale),
            cornerExponent: settings.cornerExponent,
            borderColor: settings.borderColor.simd)
        if let gradient = settings.gradientColor {
            barQuad.fill2 = gradient.simd
            barQuad.gradientDir = SceneBuilder.gradientDirection(angleDegrees: settings.gradientAngle)
            barQuad.flags |= QuadInstance.flagGradient
        }
        if settings.glass && !SceneBuilder.nativeGlassBackdrops {
            barQuad.flags |= QuadInstance.flagGlass
        }
        // background.clip: punch item-shaped holes in the bar background.
        for item in items where item.background.clip > 0 && item.drawing && item.isInBarFlow {
            guard list.holes.count < DisplayList.maxHoles,
                  let contentBox = contentBoxes[item.id], contentBox.width > 0 else { continue }
            let contentHeight = max(
                fontCache.measure(part: item.icon).height,
                fontCache.measure(part: item.label).height)
            let rect = SceneBuilder.backgroundRect(
                item: item, contentBox: contentBox, contentHeight: contentHeight)
            list.holes.append(HoleInstance(
                origin: SceneBuilder.pixelOrigin(rect, scale: scale),
                size: SceneBuilder.pixelSize(rect, scale: scale),
                radius: item.background.cornerRadius * Float(scale),
                _pad: SIMD3(repeating: 0)))
        }
        if !list.holes.isEmpty {
            barQuad.flags |= QuadInstance.flagHoles
        }
        list.quads.append(barQuad)

        // Brackets: derived backgrounds spanning their members, painted first so
        // they sit behind member content (paint order replaces window z-order).
        for item in items where item.kind == .bracket && item.drawing {
            let memberBoxes = ComponentGeometry.expandMembers(item.members, in: items).compactMap {
                contentBoxes[$0.id]
            }
            guard let union = ComponentGeometry.bracketUnion(
                memberBoxes: memberBoxes,
                paddingLeft: CGFloat(item.paddingLeft),
                paddingRight: CGFloat(item.paddingRight))
            else { continue }
            // Interactive frames are computed in BarManager before the hit
            // snapshot; here the union drives painting only.
            let height = item.background.height > 0
                ? CGFloat(item.background.height)
                : barSize.height - 4
            let rect = CGRect(
                x: union.minX + CGFloat(item.background.xOffset),
                y: barSize.height / 2 - height / 2 - CGFloat(item.yOffset) - CGFloat(item.background.yOffset),
                width: union.width,
                height: height)
            emitBackground(item.background, rect: rect, scale: scale, into: &list)
            if item.popup.isOpen { SceneBuilder.markHot(&list) }
        }

        for item in items {
            guard item.kind != .bracket, item.isVisible, item.isInBarFlow,
                  let contentBox = contentBoxes[item.id],
                  contentBox.width > 0 || item.customWidth >= 0 else { continue }
            emit(item: item, contentBox: contentBox, scale: scale, atlas: atlas, into: &list)
        }

        list.pointer = pointer
        return list
    }

    // MARK: - Popup scene

    public struct PopupScene {
        public struct GlassChip: Equatable {
            /// Popup-local, top-left origin, points. Matches the label plate.
            public var itemID: Int
            public var rect: CGRect
            public var cornerRadius: CGFloat
            public var tint: YColor
        }

        public var list = DisplayList()
        /// Popup-local hit frames.
        public var itemFrames: [(itemID: Int, frame: CGRect)] = []
        /// Label plates with `background.glass`, in popup-local points.
        public var glassChips: [GlassChip] = []
        /// Panel content size in points.
        public var sizePoints: CGSize = .zero
        /// A member scrolls its text: the panel needs the frame clock too.
        public var hasMarquee: Bool { list.hasMarquee }
        /// Marquee text needs the display link.
        public var needsContinuousFrames: Bool { list.needsContinuousFrames }
    }

    /// Set for the duration of `buildPopup` so a glass label plate is recorded
    /// next to the quad. Bar scenes leave this off.
    private var collectGlassChips = false
    private var glassChipItemID = 0
    private var glassChipBuffer: [PopupScene.GlassChip] = []

    /// Vertical (or horizontal) stack of the host's popup members.
    public func buildPopup(
        host: Item,
        members: [Item],
        scale: CGFloat,
        atlas: GlyphAtlas
    ) -> PopupScene {
        var scene = PopupScene()
        activeAtlas = atlas
        collectGlassChips = true
        glassChipBuffer.removeAll(keepingCapacity: true)
        defer { collectGlassChips = false }
        let visible = members.filter { $0.drawing }
        guard !visible.isEmpty else { return scene }

        let rows = visible.map { member -> (itemID: Int, size: CGSize, paddingLeft: CGFloat, paddingRight: CGFloat) in
            let iconSize = fontCache.measure(part: member.icon)
            let labelSize = fontCache.measure(part: member.label)
            let measured = MeasuredContent(iconSize: iconSize, labelSize: labelSize)
            let width = Layout.contentLength(item: member, measured: measured)
            let contentHeight = max(iconSize.height, labelSize.height,
                                    CGFloat(member.background.height),
                                    CGFloat(member.gauge?.diameter ?? 0),
                                    CGFloat(member.image?.drawing == true ? member.image!.size : 0))
            // Blank rows (separators: background only, no parts) skip the
            // text-row minimum — a hairline shouldn't cost a full row.
            let bare = !member.icon.drawing && !member.label.drawing
                && member.graph == nil && member.slider == nil
                && member.gauge == nil && member.image?.drawing != true
            let height = bare ? max(contentHeight + 8, 10) : max(contentHeight + 8, 22)
            return (member.id, CGSize(width: width, height: height),
                    CGFloat(member.paddingLeft), CGFloat(member.paddingRight))
        }

        let layout = ComponentGeometry.popupLayout(
            rows: rows,
            cellHeight: CGFloat(host.popup.cellHeight),
            horizontal: host.popup.horizontal,
            wrapWidth: CGFloat(host.popup.wrapWidth),
            inset: 6)
        scene.sizePoints = layout.contentSize

        // Panel background.
        emitBackground(
            host.popup.background,
            rect: CGRect(origin: .zero, size: layout.contentSize),
            scale: scale,
            forceHeight: true,
            into: &scene.list)

        for member in visible {
            guard let box = layout.boxes[member.id] else { continue }
            scene.itemFrames.append((member.id, CGRect(
                x: box.minX - CGFloat(member.paddingLeft),
                y: box.minY,
                width: box.width + CGFloat(member.paddingLeft) + CGFloat(member.paddingRight),
                height: box.height)))
            glassChipItemID = member.id
            emit(item: member, contentBox: box, scale: scale, atlas: atlas, into: &scene.list)
        }
        scene.glassChips = glassChipBuffer
        scene.list.pointer = pointer
        return scene
    }

    // MARK: - Item emission

    private func emit(
        item: Item,
        contentBox: CGRect,
        scale: CGFloat,
        atlas: GlyphAtlas,
        into list: inout DisplayList
    ) {
        let iconSize = fontCache.measure(part: item.icon)
        let labelSize = fontCache.measure(part: item.label)
        let contentHeight = max(iconSize.height, labelSize.height)
        // y_offset is positive-up (sketchybar convention); our coordinates are y-down.
        let centerY = contentBox.midY - CGFloat(item.yOffset)

        // Background + shadow.
        if item.background.drawing {
            let backgroundRect = SceneBuilder.backgroundRect(
                item: item, contentBox: contentBox, contentHeight: contentHeight)
            emitBackground(item.background, rect: backgroundRect, scale: scale, into: &list)
            if item.popup.isOpen { SceneBuilder.markHot(&list) }
        }

        let measured = MeasuredContent(iconSize: iconSize, labelSize: labelSize)
        var penX = contentBox.minX + SceneBuilder.alignmentOffset(item: item, measured: measured)

        // Fixed-width items clip their content to the content box: width
        // animations must be a clipped reveal, never overprint neighbors.
        let clip: CGRect? = item.customWidth >= 0
            ? CGRect(
                x: (contentBox.minX * scale).rounded(),
                y: (contentBox.minY * scale).rounded(),
                width: (contentBox.width * scale).rounded(),
                height: (contentBox.height * scale).rounded())
            : nil

        // Icon, sandwich content, then label (paddings advance the pen even
        // for empty strings — sketchybar parity). Fixed-width parts receive
        // the SLOT origin; their paddings/alignment resolve inside emitText.
        if let image = item.image, image.drawing, !image.source.isEmpty, image.align != "r" {
            penX += CGFloat(image.paddingLeft)
            emitImage(image, penX: penX, centerY: centerY, scale: scale,
                      atlas: atlas, into: &list)
            penX += CGFloat(image.size) + CGFloat(image.paddingRight)
        }
        if item.icon.drawing {
            if item.icon.customWidth >= 0 {
                emitText(part: item.icon, penX: penX, centerY: centerY,
                         scale: scale, atlas: atlas, clip: clip, centerInk: true, into: &list)
                penX += CGFloat(item.icon.customWidth)
            } else {
                penX += CGFloat(item.icon.paddingLeft)
                emitText(part: item.icon, penX: penX, centerY: centerY,
                         scale: scale, atlas: atlas, clip: clip, centerInk: true, into: &list)
                penX += iconSize.width + CGFloat(item.icon.paddingRight)
            }
        }
        if let graph = item.graph {
            emitGraph(graph, item: item, penX: penX, contentBox: contentBox,
                      centerY: centerY, scale: scale, atlas: atlas, into: &list)
            penX += graph.layoutWidth
        }
        if let slider = item.slider {
            // The track origin comes from the shared helper -- the same
            // computation BarManager.updateSlider maps presses through -- so
            // a press can never land on a fraction the frame did not paint.
            penX = SceneBuilder.sliderTrackX(item: item, contentBox: contentBox, measured: measured)
            emitSlider(slider, penX: penX, centerY: centerY,
                       scale: scale, atlas: atlas, clip: clip, into: &list)
            penX += CGFloat(slider.width)
        }
        if let gauge = item.gauge {
            emitGauge(gauge, label: item.label, penX: penX, centerY: centerY,
                      scale: scale, atlas: atlas, clip: clip, into: &list)
            penX += CGFloat(gauge.diameter)
        }
        if let alias = item.alias {
            let display = alias.displaySize(backingScale: scale)
            if let cgImage = alias.captured,
               let entry = atlas.liveEntry(cgImage: cgImage, cacheKey: "alias:\(item.id)") {
                let rect = CGRect(x: penX, y: centerY - display.height / 2,
                                  width: display.width, height: display.height)
                list.glyphs.append(GlyphInstance(
                    origin: SIMD2(Float(rect.minX * scale), Float(rect.minY * scale)),
                    size: SIMD2(Float(rect.width * scale), Float(rect.height * scale)),
                    uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize,
                    color: SIMD4(1, 1, 1, 1),
                    flags: GlyphInstance.flagColorGlyph))
            }
            penX += display.width
        }
        if item.gauge == nil, item.label.drawing {
            if item.label.customWidth >= 0 {
                emitText(part: item.label, penX: penX, centerY: centerY,
                         scale: scale, atlas: atlas, clip: clip,
                         marquee: item.scrollTexts, into: &list)
                penX += CGFloat(item.label.customWidth)
            } else {
                penX += CGFloat(item.label.paddingLeft)
                emitText(part: item.label, penX: penX, centerY: centerY,
                         scale: scale, atlas: atlas, clip: clip,
                         marquee: item.scrollTexts, into: &list)
                penX += labelSize.width + CGFloat(item.label.paddingRight)
            }
        }
        // image.align=r: the image trails the label (spinner beside a title).
        if let image = item.image, image.drawing, !image.source.isEmpty, image.align == "r" {
            penX += CGFloat(image.paddingLeft)
            emitImage(image, penX: penX, centerY: centerY, scale: scale,
                      atlas: atlas, into: &list)
        }
    }

    /// The item background's rect (bar-local, y-down) — shared with the glass
    /// backdrop sync and the bar-background clip hole so both land exactly
    /// under the painted pill. background.padding_left/right widen the pill
    /// beyond the content box; the hit frame stays the content width
    /// (sketchybar behavior).
    static func backgroundRect(item: Item, contentBox: CGRect, contentHeight: CGFloat) -> CGRect {
        let centerY = contentBox.midY - CGFloat(item.yOffset)
        let backgroundHeight = item.background.height > 0
            ? CGFloat(item.background.height)
            : min(contentBox.height, contentHeight + 8)
        let paddingLeft = CGFloat(item.background.paddingLeft)
        let paddingRight = CGFloat(item.background.paddingRight)
        return CGRect(
            x: contentBox.minX - paddingLeft + CGFloat(item.background.xOffset),
            y: centerY - backgroundHeight / 2 - CGFloat(item.background.yOffset),
            width: contentBox.width + paddingLeft + paddingRight,
            height: backgroundHeight)
    }

    /// Fixed-width alignment slack (unclamped: overflow anchors per align and
    /// the item clip trims the far side — sketchybar behavior). Zero for a
    /// dynamic-width item.
    static func alignmentOffset(item: Item, measured: MeasuredContent) -> CGFloat {
        guard item.customWidth >= 0 else { return 0 }
        let slack = CGFloat(item.customWidth) - Layout.naturalLength(item: item, measured: measured)
        switch item.align {
        case "c": return slack / 2
        case "r": return slack
        default: return 0
        }
    }

    /// Bar-local x of a slider's track: the pen position `emit` reaches after
    /// the alignment slack, a leading image, the icon (its paddings advance
    /// even for an empty string; a fixed icon width replaces them) and a
    /// graph. BarManager.updateSlider maps presses through this same
    /// function, so the hit side cannot drift from the painted track — its
    /// own copy once clamped the slack and skipped the paddings of an empty
    /// icon, and the media widget kept its icon at natural width to dodge
    /// that. (The Windows port clamps the slack deliberately and should drop
    /// the clamp.)
    static func sliderTrackX(item: Item, contentBox: CGRect, measured: MeasuredContent) -> CGFloat {
        var penX = contentBox.minX + alignmentOffset(item: item, measured: measured)
        if let image = item.image, image.align != "r" {
            penX += image.advance
        }
        if item.icon.drawing {
            penX += Layout.partAdvance(item.icon, inkWidth: measured.iconSize.width)
        }
        if let graph = item.graph {
            penX += graph.layoutWidth
        }
        return penX
    }

    /// Plot origin and width of a bars graph, in the same space as item frames.
    /// Matches `emitGraph`: alignment slack, a leading image, the icon, then
    /// the border inset. Nil unless the item is a bars graph.
    static func barPlotOrigin(
        item: Item, contentBox: CGRect, measured: MeasuredContent
    ) -> (x: CGFloat, width: CGFloat)? {
        guard let graph = item.graph, graph.style == .bars else { return nil }
        var penX = contentBox.minX + alignmentOffset(item: item, measured: measured)
        if let image = item.image, image.align != "r" {
            penX += image.advance
        }
        if item.icon.drawing {
            penX += Layout.partAdvance(item.icon, inkWidth: measured.iconSize.width)
        }
        let height = item.background.height > 0
            ? CGFloat(item.background.height)
            : contentBox.height - 2
        let borderPaints = item.background.drawing
            && item.background.borderWidth > 0
            && item.background.borderColor.alpha > 0
        let inset = borderPaints
            ? max(0, min(CGFloat(item.background.borderWidth),
                         graph.plotWidthPoints / 2, height / 2))
            : 0
        let width = graph.plotWidthPoints - 2 * inset
        guard width > 0 else { return nil }
        return (penX + inset, width)
    }

    // MARK: - Components

    private func emitGraph(
        _ graph: GraphState,
        item: Item,
        penX: CGFloat,
        contentBox: CGRect,
        centerY: CGFloat,
        scale: CGFloat,
        atlas: GlyphAtlas,
        into list: inout DisplayList
    ) {
        let height = item.background.height > 0
            ? CGFloat(item.background.height)
            : contentBox.height - 2
        // A bordered plate frames the graph: inset the box by the border
        // width so stroke and fill run inside the frame instead of over it.
        // Only a border that actually PAINTS earns the inset. border_width is
        // inherited wholesale from the --default prototype and the usual way
        // to switch a plate off is a transparent colour, not a zero width
        // (examples/sketchybar-port's cpu/battery graphs do exactly that), so
        // keying on the width alone shrank those graphs by a border on every
        // side with no frame anywhere to justify it. Clamped to half the box:
        // a border wider than the graph must not invert it.
        let borderPaints = item.background.drawing
            && item.background.borderWidth > 0
            && item.background.borderColor.alpha > 0
        let inset = borderPaints
            ? max(0, min(CGFloat(item.background.borderWidth),
                         graph.plotWidthPoints / 2, height / 2))
            : 0
        let plotWidth = graph.plotWidthPoints
        let box = CGRect(
            x: (penX + inset) * scale,
            y: (centerY - height / 2 + inset) * scale,
            width: (plotWidth - 2 * inset) * scale,
            height: (height - 2 * inset) * scale)

        if graph.style == .bars {
            emitBarGraph(graph, boxPoints: CGRect(
                x: penX + inset,
                y: centerY - height / 2 + inset,
                width: plotWidth - 2 * inset,
                height: height - 2 * inset),
                scale: scale, atlas: atlas, into: &list)
            return
        }

        let rightToLeft = item.position == .right || item.position == .centerLeft
        let tessellation = ComponentGeometry.tessellateGraph(
            samples: graph.ordered(),
            box: box,
            lineWidth: CGFloat(graph.lineWidth) * scale,
            rightToLeft: rightToLeft)

        let fillColor = graph.effectiveFillColor.simd
        let lineColor = graph.lineColor.simd
        list.triangles.append(contentsOf: tessellation.fill.map { ShapeVertex(position: $0, color: fillColor) })
        list.triangles.append(contentsOf: tessellation.line.map { ShapeVertex(position: $0, color: lineColor) })
    }

    /// Vertical histogram. Battery level uses a 0–100 axis; the 10-day energy
    /// chart sets axisMax to 150 so a full bar is 150% of capacity. Charging
    /// flags reserve a band under the 0% line for a short downward bar and one
    /// bolt per contiguous run.
    private func emitBarGraph(
        _ graph: GraphState,
        boxPoints: CGRect,
        scale: CGFloat,
        atlas: GlyphAtlas,
        into list: inout DisplayList
    ) {
        let samples = graph.ordered()
        guard !samples.isEmpty, boxPoints.width > 0, boxPoints.height > 0 else { return }
        let color = graph.lineColor.simd
        let count = CGFloat(samples.count)
        let stride = boxPoints.width / count
        // A handful of daily bars need a real gap, like System Settings.
        // A dense 24-hour series stays a hairline apart.
        let gap = samples.count <= 14 ? max(stride * 0.32, 2) : 1
        let barWidth = max(stride - gap, 0.5)
        let axisMax = CGFloat(max(graph.axisMax, 1))
        // Room under 0% for the charging stubs and bolt. Only when marks are
        // set, so the 10-day chart (no marks) keeps its full plot.
        let band: CGFloat = graph.marks.isEmpty ? 0 : 18
        let plotBottom = boxPoints.maxY - band
        let plotHeight = max(boxPoints.height - band, 1)

        func yFor(fraction: CGFloat) -> CGFloat {
            plotBottom - plotHeight * fraction
        }

        func brighten(_ fill: SIMD4<Float>, amount: Float) -> SIMD4<Float> {
            let t = amount * 0.55
            return SIMD4(
                fill.x + (1 - fill.x) * t,
                fill.y + (1 - fill.y) * t,
                fill.z + (1 - fill.z) * t,
                min(1, fill.w + (1 - fill.w) * t))
        }

        // Horizontal grid. fraction is the sample scale (1 = axis max).
        let axisLabels: [(String, CGFloat)]
        if axisMax >= 140 {
            axisLabels = [("150%", 1), ("100%", 100 / axisMax), ("50%", 50 / axisMax), ("0%", 0)]
        } else {
            axisLabels = [("100%", 1), ("50%", 0.5), ("0%", 0)]
        }
        for (_, fraction) in axisLabels {
            let y = yFor(fraction: fraction)
            let line = CGRect(x: boxPoints.minX, y: y - 0.5, width: boxPoints.width, height: 1)
            list.quads.append(QuadInstance(
                origin: SceneBuilder.pixelOrigin(line, scale: scale),
                size: SceneBuilder.pixelSize(line, scale: scale),
                radii: .zero,
                fill: SIMD4(1, 1, 1, fraction == 0 ? 0.16 : 0.12)))
        }

        if samples.count <= 14 {
            for index in 0...samples.count {
                let x = boxPoints.minX + CGFloat(index) * stride
                let line = CGRect(x: x, y: boxPoints.minY, width: 1, height: plotHeight)
                list.quads.append(QuadInstance(
                    origin: SceneBuilder.pixelOrigin(line, scale: scale),
                    size: SceneBuilder.pixelSize(line, scale: scale),
                    radii: .zero,
                    fill: SIMD4(1, 1, 1, 0.08)))
            }
        }

        let hover = graph.hoverIndex
        let emphasis = graph.hoverAmount
        for (index, sample) in samples.enumerated() {
            let level = CGFloat(min(1, max(0, sample)))
            let emphasized = hover == index && emphasis > 0.001
            if level <= 0.001 && !emphasized { continue }
            let grow: CGFloat = emphasized ? 3 * CGFloat(emphasis) : 0
            let barHeight = min(plotHeight, max(level * plotHeight, emphasized ? 2 : 0) + grow)
            let x = boxPoints.minX + CGFloat(index) * stride + (stride - barWidth) / 2
            let bar = CGRect(
                x: x,
                y: plotBottom - barHeight,
                width: barWidth,
                height: barHeight)
            let fill = emphasized ? brighten(color, amount: emphasis) : color
            list.quads.append(QuadInstance(
                origin: SceneBuilder.pixelOrigin(bar, scale: scale),
                size: SceneBuilder.pixelSize(bar, scale: scale),
                radii: SIMD4(Float(2 * scale), Float(2 * scale), 0, 0),
                fill: fill))
        }

        // The old single tick sits under the plot. Charging bolts replace it
        // once the below-axis band is reserved.
        if band == 0, let tick = graph.tickIndex, tick >= 0, tick < samples.count {
            let x = boxPoints.minX + CGFloat(tick) * stride + (stride - barWidth) / 2
            let mark = CGRect(
                x: x,
                y: boxPoints.maxY + 3,
                width: barWidth,
                height: 5)
            list.quads.append(QuadInstance(
                origin: SceneBuilder.pixelOrigin(mark, scale: scale),
                size: SceneBuilder.pixelSize(mark, scale: scale),
                radii: SIMD4(repeating: Float(1 * scale)),
                fill: color))
        }

        if band > 0 {
            let chargeColor = YColor(argb: 0xff248a3d).simd
            let stubHeight: CGFloat = 8
            for index in samples.indices where index < graph.marks.count && graph.marks[index] {
                let emphasized = hover == index && emphasis > 0.001
                let x = boxPoints.minX + CGFloat(index) * stride + (stride - barWidth) / 2
                let stub = CGRect(x: x, y: plotBottom, width: barWidth, height: stubHeight)
                list.quads.append(QuadInstance(
                    origin: SceneBuilder.pixelOrigin(stub, scale: scale),
                    size: SceneBuilder.pixelSize(stub, scale: scale),
                    radii: SIMD4(0, 0, Float(2 * scale), Float(2 * scale)),
                    fill: emphasized ? brighten(chargeColor, amount: emphasis) : chargeColor))
            }

            var runs: [(start: Int, end: Int)] = []
            var runStart: Int?
            for index in 0...samples.count {
                let on = index < samples.count && index < graph.marks.count && graph.marks[index]
                if on {
                    if runStart == nil { runStart = index }
                } else if let start = runStart {
                    runs.append((start, index))
                    runStart = nil
                }
            }
            var bolt = TextPart()
            bolt.string = "sf:bolt.fill"
            bolt.font.size = 12
            bolt.color = YColor(argb: 0xEBFFFFFF)
            let ink = fontCache.measure(part: bolt)
            let half = ink.width / 2
            for run in runs {
                let left = boxPoints.minX + CGFloat(run.start) * stride + (stride - barWidth) / 2
                let right = boxPoints.minX + CGFloat(run.end - 1) * stride
                    + (stride - barWidth) / 2 + barWidth
                let mid = min(max((left + right) / 2, boxPoints.minX + half),
                              boxPoints.maxX - half)
                emitText(part: bolt,
                         penX: mid - half,
                         centerY: plotBottom + band / 2,
                         scale: scale, atlas: atlas, clip: nil, centerInk: true, into: &list)
            }
        }

        let axisX = boxPoints.maxX + 4
        for (label, fraction) in axisLabels {
            var part = TextPart()
            part.string = label
            part.font.size = 10
            part.font.style = "Regular"
            part.color = YColor(argb: 0x8CFF_FFFF)
            let ink = fontCache.measure(part: part)
            emitText(part: part,
                     penX: axisX + GraphState.barsAxisReserve - 4 - ink.width,
                     centerY: yFor(fraction: fraction),
                     scale: scale, atlas: atlas, clip: nil, into: &list)
        }
    }

    /// Bitmap image (app icon) via the atlas color page, vertically centered.
    private func emitImage(
        _ image: ImageState,
        penX: CGFloat,
        centerY: CGFloat,
        scale: CGFloat,
        atlas: GlyphAtlas,
        into list: inout DisplayList
    ) {
        guard let nsImage = image.resolvedImage() else { return }
        let sizePoints = CGSize(width: CGFloat(image.size), height: CGFloat(image.size))
        let key = SceneBuilder.imageCacheKey(
            source: image.source, size: image.size, rotation: image.rotation)
        guard let entry = atlas.entry(colorImage: nsImage, cacheKey: key,
                                      sizePoints: sizePoints) else { return }
        // image.y_offset is positive-up like the text offsets; y-down here.
        let rect = CGRect(
            x: penX,
            y: centerY - sizePoints.height / 2 - CGFloat(image.yOffset),
            width: sizePoints.width,
            height: sizePoints.height)
        var flags = GlyphInstance.flagColorGlyph
        if image.desaturate { flags |= GlyphInstance.flagDesaturate }
        list.glyphs.append(GlyphInstance(
            origin: SIMD2(Float(rect.minX * scale), Float(rect.minY * scale)),
            size: SIMD2(Float(rect.width * scale), Float(rect.height * scale)),
            uvOrigin: entry.uvOrigin,
            uvSize: entry.uvSize,
            color: SIMD4(1, 1, 1, 1),
            flags: flags))
    }

    /// Speedometer arc (flagArc quad) with the item's label centered in the
    /// ring — a gauge item's label lives inside the dial, not beside it.
    private func emitGauge(
        _ gauge: GaugeState,
        label: TextPart,
        penX: CGFloat,
        centerY: CGFloat,
        scale: CGFloat,
        atlas: GlyphAtlas,
        clip: CGRect?,
        into list: inout DisplayList
    ) {
        let size = CGFloat(gauge.diameter)
        let rect = CGRect(x: penX, y: centerY - size / 2, width: size, height: size)
        var quad = QuadInstance(
            origin: SceneBuilder.pixelOrigin(rect, scale: scale),
            size: SceneBuilder.pixelSize(rect, scale: scale),
            radii: SIMD4(repeating: Float(size / 2) * Float(scale)),
            fill: gauge.trackColor.simd,
            borderWidth: gauge.thickness * Float(scale),
            cornerExponent: 2,
            borderColor: gauge.color.simd)
        quad.gradientDir = SIMD2(min(1, max(0, gauge.percentage / 100)), 0)
        quad.flags |= QuadInstance.flagArc
        list.quads.append(quad)

        if label.drawing {
            let labelSize = fontCache.measure(part: label)
            emitText(part: label, penX: rect.midX - labelSize.width / 2,
                     centerY: centerY, scale: scale, atlas: atlas, clip: clip,
                     centerInk: true, into: &list)
        }
    }

    private func emitSlider(
        _ slider: SliderState,
        penX: CGFloat,
        centerY: CGFloat,
        scale: CGFloat,
        atlas: GlyphAtlas,
        clip: CGRect?,
        into list: inout DisplayList
    ) {
        let trackHeight = CGFloat(slider.background.height > 0 ? slider.background.height : 6)
        let track = CGRect(
            x: penX,
            y: centerY - trackHeight / 2,
            width: CGFloat(slider.width),
            height: trackHeight)
        emitBackground(slider.background, rect: track, scale: scale, forceHeight: true, into: &list)

        let fraction = CGFloat(min(100, max(0, slider.percentage))) / 100
        if fraction > 0 {
            // Inset the fill inside the shell border so a capsule meter does not
            // paint over its own rim.
            let inset = CGFloat(slider.background.borderWidth)
            let inner = track.insetBy(dx: inset, dy: inset)
            if inner.width > 0, inner.height > 0 {
                let highlight = CGRect(x: inner.minX, y: inner.minY,
                                       width: max(inner.width * fraction, 0), height: inner.height)
                let fillRadius = max(0, slider.background.cornerRadius - Float(inset))
                list.quads.append(QuadInstance(
                    origin: SceneBuilder.pixelOrigin(highlight, scale: scale),
                    size: SceneBuilder.pixelSize(highlight, scale: scale),
                    radii: SIMD4(repeating: fillRadius * Float(scale)),
                    fill: slider.highlightColor.simd))
            }
        }

        if !slider.knob.string.isEmpty {
            let knobSize = fontCache.measure(part: slider.knob)
            let knobCenterX = track.minX + track.width * fraction
            let knobX = min(max(knobCenterX - knobSize.width / 2, track.minX),
                            track.maxX - knobSize.width)
            // The knob is one glyph, so it centres its ink like an icon does;
            // knob.y_offset remains the override on top.
            emitText(part: slider.knob, penX: knobX, centerY: centerY,
                     scale: scale, atlas: atlas, clip: clip, centerInk: true, into: &list)
        }
    }

    /// Shared rounded-rect background + shadow emission (items, brackets,
    /// slider tracks, popup panels, tooltips all come through here).
    private func emitBackground(
        _ background: BackgroundStyle,
        rect: CGRect,
        scale: CGFloat,
        forceHeight: Bool = false,
        into list: inout DisplayList
    ) {
        guard background.drawing || forceHeight else { return }
        let radius = background.cornerRadius * Float(scale)
        let radii = SIMD4<Float>(repeating: radius)

        if background.shadow.drawing {
            let offset = background.shadow.offset
            let shadowRect = rect.offsetBy(dx: offset.width, dy: -offset.height)
            var shadow = QuadInstance(
                origin: SceneBuilder.pixelOrigin(shadowRect, scale: scale),
                size: SceneBuilder.pixelSize(shadowRect, scale: scale),
                radii: radii,
                fill: background.shadow.color.simd)
            // shadow.blur > 0 turns the hard offset copy into a falloff. The
            // blur has to live OUTSIDE the shape, but a quad's rect IS its
            // shape's bounding box, so a falloff drawn within it would be
            // clipped at exactly the edge it exists to soften. Grow the drawn
            // rect by the blur on every side and carry the true half size
            // across in fill2.xy — free on a shadow quad, whose gradient
            // fields are otherwise unused. Instance ABI identical to the
            // Windows port's pushShadow: the 112-byte layout is untouched.
            let blurPx = Float(CGFloat(background.shadow.blur) * scale)
            if blurPx > 0 {
                // Order matters: fill2 records the half size BEFORE the grow.
                shadow.fill2 = SIMD4(shadow.size.x * 0.5, shadow.size.y * 0.5, 0, 0)
                shadow.origin -= SIMD2(repeating: blurPx)
                shadow.size += SIMD2(repeating: blurPx * 2)
                shadow.gradientDir = SIMD2(blurPx, 0)
                shadow.flags |= QuadInstance.flagShadow
            }
            list.quads.append(shadow)
        }

        list.quads.append(SceneBuilder.backgroundQuad(background, rect: rect, scale: scale))
        if background.sheen, !SceneBuilder.nativeGlassBackdrops { list.hasSheen = true }

        // background.image: aspect-fit inside the background rect, scaled.
        if background.imageDrawing, !background.imageSource.isEmpty,
           let atlas = activeAtlas,
           let image = ImageState.resolve(source: background.imageSource) {
            let fitHeight = rect.height * CGFloat(background.imageScale)
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            let display = CGSize(width: fitHeight * aspect, height: fitHeight)
            let key = "bgimg:\(background.imageSource)@\(Int(display.width))x\(Int(display.height))"
            if let entry = atlas.entry(colorImage: image, cacheKey: key, sizePoints: display) {
                let imageRect = CGRect(
                    x: rect.midX - display.width / 2,
                    y: rect.midY - display.height / 2,
                    width: display.width, height: display.height)
                list.glyphs.append(GlyphInstance(
                    origin: SIMD2(Float(imageRect.minX * scale), Float(imageRect.minY * scale)),
                    size: SIMD2(Float(imageRect.width * scale), Float(imageRect.height * scale)),
                    uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize,
                    color: SIMD4(1, 1, 1, 1),
                    flags: GlyphInstance.flagColorGlyph))
            }
        }
    }

    /// The plate quad of a background style (fill, border, gradient, glass),
    /// shared by emitBackground and the per-part plates emitText draws.
    static func backgroundQuad(_ background: BackgroundStyle, rect: CGRect, scale: CGFloat) -> QuadInstance {
        var quad = QuadInstance(
            origin: pixelOrigin(rect, scale: scale),
            size: pixelSize(rect, scale: scale),
            radii: SIMD4(repeating: background.cornerRadius * Float(scale)),
            fill: background.color.simd,
            borderWidth: background.borderWidth * Float(scale),
            cornerExponent: background.cornerExponent,
            borderColor: background.borderColor.simd)
        if let gradient = background.gradientColor {
            quad.fill2 = gradient.simd
            quad.gradientDir = gradientDirection(angleDegrees: background.gradientAngle)
            quad.flags |= QuadInstance.flagGradient
        }
        if background.glass && !nativeGlassBackdrops {
            quad.flags |= QuadInstance.flagGlass
        }
        // Painted lip/shade/specular is the pre-26 stand-in. On macOS 26 the
        // system material is the glass, and a Metal highlight over it reads
        // as a fake shine.
        if background.sheen, !nativeGlassBackdrops {
            quad.flags |= QuadInstance.flagSheen
        }
        return quad
    }

    /// The plate just emitted is the open-popup trigger: its sheen specular
    /// stays lit for as long as the popup is up.
    private static func markHot(_ list: inout DisplayList) {
        guard !list.quads.isEmpty else { return }
        list.quads[list.quads.count - 1].flags |= QuadInstance.flagHot
    }

    /// The same plate, trimmed to a clip rect (device px) the way
    /// `glyphInstance` trims a glyph. Quads carry no clip field and the
    /// pipeline sets no scissor, so the trim is geometric: intersect, and drop
    /// the radius of every corner sitting on a cut edge so the cut reads as a
    /// straight edge instead of a rounded bulge mid-item. nil when the clip
    /// removes the plate entirely.
    static func clippedQuad(
        _ background: BackgroundStyle, rect: CGRect, scale: CGFloat, clip: CGRect?
    ) -> QuadInstance? {
        var quad = backgroundQuad(background, rect: rect, scale: scale)
        guard let clip else { return quad }
        let device = CGRect(x: CGFloat(quad.origin.x), y: CGFloat(quad.origin.y),
                            width: CGFloat(quad.size.x), height: CGFloat(quad.size.y))
        let visible = device.intersection(clip)
        guard !visible.isEmpty else { return nil }
        guard visible != device else { return quad }
        // radii is (topLeft, topRight, bottomRight, bottomLeft).
        if visible.minX > device.minX { quad.radii.x = 0; quad.radii.w = 0 }
        if visible.maxX < device.maxX { quad.radii.y = 0; quad.radii.z = 0 }
        if visible.minY > device.minY { quad.radii.x = 0; quad.radii.y = 0 }
        if visible.maxY < device.maxY { quad.radii.z = 0; quad.radii.w = 0 }
        quad.origin = SIMD2(Float(visible.minX), Float(visible.minY))
        quad.size = SIMD2(Float(visible.width), Float(visible.height))
        return quad
    }

    /// Real Liquid Glass (NSGlassEffectView) exists on macOS 26+: the backdrop
    /// itself refracts, so the shader's painted rim and sheen stay off there.
    public static let nativeGlassBackdrops: Bool = {
        if #available(macOS 26.0, *) { return true }
        return false
    }()

    // MARK: - Tooltip

    /// Small dark bubble with one line of text (hover tooltips).
    public func buildTooltip(text: String, scale: CGFloat, atlas: GlyphAtlas)
        -> (list: DisplayList, sizePoints: CGSize) {
        activeAtlas = atlas
        var part = TextPart()
        part.string = text
        part.font.size = 11
        part.color = YColor(argb: 0xFFFF_FFFF)
        let ink = fontCache.measure(part: part)
        let size = CGSize(width: ink.width + 20, height: max(ink.height + 10, 24))
        var list = DisplayList()
        var background = BackgroundStyle()
        background.drawing = true
        background.color = YColor(argb: 0xF220_2024)
        background.cornerRadius = 6
        emitBackground(background, rect: CGRect(origin: .zero, size: size),
                       scale: scale, forceHeight: true, into: &list)
        emitText(part: part, penX: 10, centerY: size.height / 2,
                 scale: scale, atlas: atlas, clip: nil, into: &list)
        return (list, size)
    }

    // MARK: - Text

    private func emitText(
        part: TextPart,
        penX: CGFloat,
        centerY: CGFloat,
        scale: CGFloat,
        atlas: GlyphAtlas,
        clip: CGRect?,
        centerInk: Bool = false,
        marquee: Bool = false,
        into list: inout DisplayList
    ) {
        let text = part.displayString
        guard !text.isEmpty else { return }
        let color = part.effectiveColor.simd
        let shadow = SceneBuilder.textShadow(part.shadow, scale: scale)
        let partCenterY = centerY - CGFloat(part.yOffset)
        var marqueeCycle: CGFloat = 0

        // Fixed-width parts: penX is the SLOT origin; paddings fold inside the
        // slot (sketchybar text_get_length override), content aligns with
        // UNCLAMPED slack (overflow anchors per align; the slot clip trims the
        // far side), and everything clips to the slot box.
        var penX = penX
        var clip = clip
        var marqueeOffset: CGFloat = 0
        if part.customWidth >= 0 {
            let ink = fontCache.naturalMeasure(part: part).width
            let slack = CGFloat(part.customWidth)
                - CGFloat(part.paddingLeft) - CGFloat(part.paddingRight) - ink
            let boxOrigin = penX
            penX += CGFloat(part.paddingLeft)
            if marquee, slack < 0 {
                // Overflowing marquee: scroll instead of clipping. The run is
                // drawn twice, one cycle apart, for a seamless wrap.
                list.hasMarquee = true
                marqueeCycle = ink + 24
                let seconds = Double(max(part.scrollDuration, 1)) / 60.0
                let speed = Double(marqueeCycle) / seconds
                marqueeOffset = CGFloat(clock * speed).truncatingRemainder(
                    dividingBy: marqueeCycle)
            } else {
                switch part.align {
                case "c": penX += slack / 2
                case "r": penX += slack
                default: break
                }
            }
            let partBox = CGRect(
                x: (boxOrigin * scale).rounded(),
                y: 0,
                width: (CGFloat(part.customWidth) * scale).rounded(),
                height: .greatestFiniteMagnitude / 2)
            clip = clip.map { $0.intersection(partBox) } ?? partBox
        }
        // An empty clip means the whole part is hidden — a collapsed slot, or
        // a collapsed ITEM (width=0, or any --animate width frame below the
        // natural content). Return before the plate too: glyphs drop out of
        // an empty clip on their own, a plate quad would not.
        if clip?.isEmpty == true { return }

        // icon.background / label.background: one plate behind the part's
        // ink, sized from the natural measure plus the plate's own paddings
        // (layout never widens for them — sketchybar parity) and centred on
        // the item's centre line, as the Windows port draws it. Emitted
        // before the marquee offset applies: the ink scrolls under a plate
        // that stays put. Quads paint before glyphs, so no ordering work.
        if part.background.drawing {
            let ink = fontCache.naturalMeasure(part: part)
            let height = part.background.height > 0
                ? CGFloat(part.background.height) : ink.height + 4
            let plate = CGRect(
                x: penX - CGFloat(part.background.paddingLeft) + CGFloat(part.background.xOffset),
                y: centerY - height / 2 - CGFloat(part.background.yOffset),
                width: ink.width + CGFloat(part.background.paddingLeft)
                    + CGFloat(part.background.paddingRight),
                height: height)
            // The plate obeys the clip the ink obeys: the natural ink it is
            // sized from can overflow a narrower slot (label.width=N below the
            // text, a marquee) or a fixed-width item, and an unclipped quad
            // would paint that overflow over its neighbours.
            if let quad = SceneBuilder.clippedQuad(
                part.background, rect: plate, scale: scale, clip: clip) {
                list.quads.append(quad)
                if part.background.sheen, !SceneBuilder.nativeGlassBackdrops {
                    list.hasSheen = true
                }
            }
            if collectGlassChips, part.background.glass {
                var recorded = plate
                if let clip {
                    let pointClip = CGRect(
                        x: clip.minX / scale, y: clip.minY / scale,
                        width: clip.width / scale, height: clip.height / scale)
                    recorded = recorded.intersection(pointClip)
                }
                if !recorded.isNull, recorded.width >= 1, recorded.height >= 1 {
                    glassChipBuffer.append(PopupScene.GlassChip(
                        itemID: glassChipItemID,
                        rect: recorded,
                        cornerRadius: CGFloat(part.background.cornerRadius),
                        tint: part.background.color))
                }
            }
        }
        penX -= marqueeOffset

        if let symbolName = FontCache.sfSymbolName(in: text) {
            guard let image = fontCache.symbolImage(name: symbolName, pointSize: CGFloat(part.font.size)),
                  let entry = atlas.entry(
                    symbolImage: image,
                    cacheKey: SceneBuilder.symbolCacheKey(name: symbolName, size: part.font.size))
            else { return }
            let originX = (penX * scale).rounded()
            let originY = (partCenterY * scale - CGFloat(entry.sizePx.y) / 2).rounded()
            list.glyphs.append(contentsOf: SceneBuilder.layeredGlyphs(
                [(entry, SIMD2(Float(originX), Float(originY)))],
                color: color, shadow: shadow, clip: clip))
            return
        }

        let shaped = fontCache.shapedLine(text: text, spec: part.font)
        // Icons (single glyphs) center their INK vertically — em-box centering
        // leaves symbol glyphs visibly off-center. Labels keep em centering so
        // mixed-case text doesn't jump with its content.
        let baselineY = centerInk && shaped.inkMaxY > shaped.inkMinY
            ? partCenterY + (shaped.inkMinY + shaped.inkMaxY) / 2
            : partCenterY + (shaped.ascent - shaped.descent) / 2
        let baselinePx = (baselineY * scale).rounded()

        guard let runs = CTLineGetGlyphRuns(shaped.line) as? [CTRun] else { return }
        // Every glyph of the part is placed first and layered once, so a
        // shadow never paints over the ink of an earlier run or marquee copy.
        var placements: [(entry: GlyphAtlas.Entry, origin: SIMD2<Float>)] = []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let runFontAny = attributes[kCTFontAttributeName as String] else { continue }
            let runFont = runFontAny as! CTFont

            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)

            let roundingSlack = max(shaped.width - shaped.inkWidth, 0) / 2
            // Marquee wrap: a second pass one cycle to the right fills the gap
            // as the first copy scrolls out; the slot clip trims both.
            let passes: [CGFloat] = marqueeCycle > 0 ? [0, marqueeCycle] : [0]
            for passOffset in passes {
                for index in 0..<count {
                    guard let entry = atlas.entry(glyph: glyphs[index], font: runFont) else { continue }
                    // Ink-aligned (-inkMinX: ink starts at the pen) with the
                    // measurement's rounding slack split evenly — otherwise up
                    // to 1.5pt of slack pools on the right and single glyphs
                    // (the apple symbol) sit visibly left of center.
                    let glyphPenX = ((penX + passOffset + positions[index].x
                                      - shaped.inkMinX + roundingSlack)
                                     * scale).rounded()
                    placements.append((entry, SIMD2(Float(glyphPenX) + entry.bearingPx.x,
                                                    Float(baselinePx) + entry.bearingPx.y)))
                }
            }
        }
        list.glyphs.append(contentsOf: SceneBuilder.layeredGlyphs(
            placements, color: color, shadow: shadow, clip: clip))
    }

    /// `icon.shadow` / `label.shadow` resolved to device pixels: the glyphs
    /// are drawn once more underneath, displaced like the background shadow
    /// (angle counter-clockwise from +x, y-down here) and rounded to whole
    /// pixels so the copy samples the atlas as crisply as the ink.
    struct TextShadow: Equatable {
        var offsetPx: SIMD2<Float>
        var color: SIMD4<Float>
    }

    static func textShadow(_ shadow: ShadowStyle, scale: CGFloat) -> TextShadow? {
        guard shadow.drawing else { return nil }
        let offset = shadow.offset
        return TextShadow(
            offsetPx: SIMD2(Float((offset.width * scale).rounded()),
                            Float((-offset.height * scale).rounded())),
            color: shadow.color.simd)
    }

    /// Glyph quads for one text part: the shadow copies first so the ink
    /// paints over them, then the ink. Both layers share the clip.
    static func layeredGlyphs(
        _ placements: [(entry: GlyphAtlas.Entry, origin: SIMD2<Float>)],
        color: SIMD4<Float>,
        shadow: TextShadow?,
        clip: CGRect?
    ) -> [GlyphInstance] {
        var instances: [GlyphInstance] = []
        instances.reserveCapacity(placements.count * (shadow == nil ? 1 : 2))
        if let shadow {
            for placement in placements {
                // Colour-page glyphs (emoji, multicolour symbols) sample the
                // BGRA atlas as-is — the shader's colour branch keeps only
                // in.color.a and ignores the shadow's rgb — so a shadow copy
                // would be a second, fully coloured emoji offset behind the
                // first, not a silhouette. Skip it; the ink still draws. A
                // real silhouette needs a shader flag emitting
                // colour.rgb * texel.a, which is beyond sketchybar parity.
                guard !placement.entry.isColor else { continue }
                if let instance = glyphInstance(
                    origin: placement.origin + shadow.offsetPx,
                    entry: placement.entry, color: shadow.color, clip: clip) {
                    instances.append(instance)
                }
            }
        }
        for placement in placements {
            if let instance = glyphInstance(
                origin: placement.origin, entry: placement.entry, color: color, clip: clip) {
                instances.append(instance)
            }
        }
        return instances
    }

    /// Build a glyph instance, intersecting the quad with an optional clip rect
    /// (device px) and remapping UVs proportionally. Axis-aligned quads make
    /// this exact — no scissor or shader support needed.
    static func glyphInstance(
        origin: SIMD2<Float>,
        entry: GlyphAtlas.Entry,
        color: SIMD4<Float>,
        clip: CGRect?
    ) -> GlyphInstance? {
        var quadOrigin = origin
        var quadSize = entry.sizePx
        var uvOrigin = entry.uvOrigin
        var uvSize = entry.uvSize

        if let clip {
            let rect = CGRect(x: CGFloat(origin.x), y: CGFloat(origin.y),
                              width: CGFloat(entry.sizePx.x), height: CGFloat(entry.sizePx.y))
            let visible = rect.intersection(clip)
            guard !visible.isEmpty, rect.width > 0, rect.height > 0 else { return nil }
            if visible != rect {
                let cutLeft = Float((visible.minX - rect.minX) / rect.width)
                let cutTop = Float((visible.minY - rect.minY) / rect.height)
                let keepX = Float(visible.width / rect.width)
                let keepY = Float(visible.height / rect.height)
                uvOrigin.x += uvSize.x * cutLeft
                uvOrigin.y += uvSize.y * cutTop
                uvSize.x *= keepX
                uvSize.y *= keepY
                quadOrigin = SIMD2(Float(visible.minX), Float(visible.minY))
                quadSize = SIMD2(Float(visible.width), Float(visible.height))
            }
        }

        return GlyphInstance(
            origin: quadOrigin,
            size: quadSize,
            uvOrigin: uvOrigin,
            uvSize: uvSize,
            color: color,
            flags: entry.isColor ? GlyphInstance.flagColorGlyph : 0)
    }

    // MARK: - Helpers

    /// Atlas keys for images and SF symbols bucket their size to the quarter
    /// point exactly as glyph keys do: an animated `image.size` or an `sf:`
    /// icon's `font.size` would otherwise mint a fresh cell per interpolation
    /// frame on a packer that never reclaims. Rotation stays per degree --
    /// spinner.lua steps 12°, and a full per-degree sweep still fits.
    nonisolated static func imageCacheKey(source: String, size: Float, rotation: Float) -> String {
        "img:\(source)@\(GlyphAtlas.quarterPoint(CGFloat(size)))r\(Int(rotation.rounded()))"
    }

    nonisolated static func symbolCacheKey(name: String, size: Float) -> String {
        "sf:\(name)#\(GlyphAtlas.quarterPoint(CGFloat(size)))"
    }

    static func pixelOrigin(_ rect: CGRect, scale: CGFloat) -> SIMD2<Float> {
        SIMD2(Float((rect.minX * scale).rounded()), Float((rect.minY * scale).rounded()))
    }

    static func pixelSize(_ rect: CGRect, scale: CGFloat) -> SIMD2<Float> {
        SIMD2(Float((rect.width * scale).rounded()), Float((rect.height * scale).rounded()))
    }

    static func gradientDirection(angleDegrees: Float) -> SIMD2<Float> {
        let radians = angleDegrees * .pi / 180
        return SIMD2(cos(radians), sin(radians))
    }
}
