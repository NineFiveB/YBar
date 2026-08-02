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
        }

        for item in items {
            guard item.kind != .bracket, item.isVisible, item.isInBarFlow,
                  let contentBox = contentBoxes[item.id],
                  contentBox.width > 0 || item.customWidth >= 0 else { continue }
            emit(item: item, contentBox: contentBox, scale: scale, atlas: atlas, into: &list)
        }

        return list
    }

    // MARK: - Popup scene

    public struct PopupScene {
        public var list = DisplayList()
        /// Popup-local hit frames.
        public var itemFrames: [(itemID: Int, frame: CGRect)] = []
        /// Panel content size in points.
        public var sizePoints: CGSize = .zero
    }

    /// Vertical (or horizontal) stack of the host's popup members.
    public func buildPopup(
        host: Item,
        members: [Item],
        scale: CGFloat,
        atlas: GlyphAtlas
    ) -> PopupScene {
        var scene = PopupScene()
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
            emit(item: member, contentBox: box, scale: scale, atlas: atlas, into: &scene.list)
        }
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
        }

        // Fixed-width alignment slack (unclamped: overflow anchors per align
        // and the clip below trims the far side — sketchybar behavior).
        var penX = contentBox.minX
        if item.customWidth >= 0 {
            let natural = Layout.naturalLength(
                item: item, measured: MeasuredContent(iconSize: iconSize, labelSize: labelSize))
            let slack = CGFloat(item.customWidth) - natural
            switch item.align {
            case "c": penX += slack / 2
            case "r": penX += slack
            default: break
            }
        }

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
        if let image = item.image, image.drawing, !image.source.isEmpty {
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
                      centerY: centerY, scale: scale, into: &list)
            penX += CGFloat(graph.capacity)
        }
        if let slider = item.slider {
            emitSlider(slider, penX: penX, centerY: centerY,
                       scale: scale, atlas: atlas, clip: clip, into: &list)
            penX += CGFloat(slider.width)
        }
        if let gauge = item.gauge {
            emitGauge(gauge, label: item.label, penX: penX, centerY: centerY,
                      scale: scale, atlas: atlas, clip: clip, into: &list)
            penX += CGFloat(gauge.diameter)
        }
        if item.gauge == nil, item.label.drawing {
            if item.label.customWidth >= 0 {
                emitText(part: item.label, penX: penX, centerY: centerY,
                         scale: scale, atlas: atlas, clip: clip, into: &list)
            } else {
                penX += CGFloat(item.label.paddingLeft)
                emitText(part: item.label, penX: penX, centerY: centerY,
                         scale: scale, atlas: atlas, clip: clip, into: &list)
            }
        }
        // TODO(v1.5): per-part backgrounds (icon.background.* / label.background.*).
    }

    /// The item background's rect (bar-local, y-down) — shared with the glass
    /// backdrop sync so blur views land exactly under the painted pill.
    static func backgroundRect(item: Item, contentBox: CGRect, contentHeight: CGFloat) -> CGRect {
        let centerY = contentBox.midY - CGFloat(item.yOffset)
        let backgroundHeight = item.background.height > 0
            ? CGFloat(item.background.height)
            : min(contentBox.height, contentHeight + 8)
        return CGRect(
            x: contentBox.minX + CGFloat(item.background.xOffset),
            y: centerY - backgroundHeight / 2 - CGFloat(item.background.yOffset),
            width: contentBox.width,
            height: backgroundHeight)
    }

    // MARK: - Components

    private func emitGraph(
        _ graph: GraphState,
        item: Item,
        penX: CGFloat,
        contentBox: CGRect,
        centerY: CGFloat,
        scale: CGFloat,
        into list: inout DisplayList
    ) {
        let height = item.background.height > 0
            ? CGFloat(item.background.height)
            : contentBox.height - 2
        let box = CGRect(
            x: penX * scale,
            y: (centerY - height / 2) * scale,
            width: CGFloat(graph.capacity) * scale,
            height: height * scale)
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
        let key = "img:\(image.source)@\(image.size)"
        guard let entry = atlas.entry(colorImage: nsImage, cacheKey: key,
                                      sizePoints: sizePoints) else { return }
        let rect = CGRect(
            x: penX,
            y: centerY - sizePoints.height / 2,
            width: sizePoints.width,
            height: sizePoints.height)
        list.glyphs.append(GlyphInstance(
            origin: SIMD2(Float(rect.minX * scale), Float(rect.minY * scale)),
            size: SIMD2(Float(rect.width * scale), Float(rect.height * scale)),
            uvOrigin: entry.uvOrigin,
            uvSize: entry.uvSize,
            color: SIMD4(1, 1, 1, 1),
            flags: GlyphInstance.flagColorGlyph))
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
            let highlight = CGRect(x: track.minX, y: track.minY,
                                   width: track.width * fraction, height: track.height)
            list.quads.append(QuadInstance(
                origin: SceneBuilder.pixelOrigin(highlight, scale: scale),
                size: SceneBuilder.pixelSize(highlight, scale: scale),
                radii: SIMD4(repeating: slider.background.cornerRadius * Float(scale)),
                fill: slider.highlightColor.simd))
        }

        if !slider.knob.string.isEmpty {
            let knobSize = fontCache.measure(part: slider.knob)
            let knobCenterX = track.minX + track.width * fraction
            let knobX = min(max(knobCenterX - knobSize.width / 2, track.minX),
                            track.maxX - knobSize.width)
            emitText(part: slider.knob, penX: knobX, centerY: centerY,
                     scale: scale, atlas: atlas, clip: clip, into: &list)
        }
    }

    /// Shared rounded-rect background + hard shadow emission.
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
            list.quads.append(QuadInstance(
                origin: SceneBuilder.pixelOrigin(shadowRect, scale: scale),
                size: SceneBuilder.pixelSize(shadowRect, scale: scale),
                radii: radii,
                fill: background.shadow.color.simd))
        }

        var quad = QuadInstance(
            origin: SceneBuilder.pixelOrigin(rect, scale: scale),
            size: SceneBuilder.pixelSize(rect, scale: scale),
            radii: radii,
            fill: background.color.simd,
            borderWidth: background.borderWidth * Float(scale),
            cornerExponent: background.cornerExponent,
            borderColor: background.borderColor.simd)
        if let gradient = background.gradientColor {
            quad.fill2 = gradient.simd
            quad.gradientDir = SceneBuilder.gradientDirection(angleDegrees: background.gradientAngle)
            quad.flags |= QuadInstance.flagGradient
        }
        if background.glass && !SceneBuilder.nativeGlassBackdrops {
            quad.flags |= QuadInstance.flagGlass
        }
        list.quads.append(quad)
    }

    /// Real Liquid Glass (NSGlassEffectView) exists on macOS 26+: the backdrop
    /// itself refracts and glints, so the shader's painted rim/sheen imitation
    /// stays off there — layered on the true material it reads as a glow
    /// outline, not glass. Pre-26 systems keep the shader approximation.
    public static let nativeGlassBackdrops: Bool = {
        if #available(macOS 26.0, *) { return true }
        return false
    }()

    // MARK: - Text

    private func emitText(
        part: TextPart,
        penX: CGFloat,
        centerY: CGFloat,
        scale: CGFloat,
        atlas: GlyphAtlas,
        clip: CGRect?,
        centerInk: Bool = false,
        into list: inout DisplayList
    ) {
        let text = part.displayString
        guard !text.isEmpty else { return }
        let color = part.effectiveColor.simd
        let partCenterY = centerY - CGFloat(part.yOffset)

        // Fixed-width parts: penX is the SLOT origin; paddings fold inside the
        // slot (sketchybar text_get_length override), content aligns with
        // UNCLAMPED slack (overflow anchors per align; the slot clip trims the
        // far side), and everything clips to the slot box.
        var penX = penX
        var clip = clip
        if part.customWidth >= 0 {
            let ink = fontCache.naturalMeasure(part: part).width
            let slack = CGFloat(part.customWidth)
                - CGFloat(part.paddingLeft) - CGFloat(part.paddingRight) - ink
            let boxOrigin = penX
            penX += CGFloat(part.paddingLeft)
            switch part.align {
            case "c": penX += slack / 2
            case "r": penX += slack
            default: break
            }
            let partBox = CGRect(
                x: (boxOrigin * scale).rounded(),
                y: 0,
                width: (CGFloat(part.customWidth) * scale).rounded(),
                height: .greatestFiniteMagnitude / 2)
            clip = clip.map { $0.intersection(partBox) } ?? partBox
            if clip?.isEmpty == true { return }
        }

        if let symbolName = FontCache.sfSymbolName(in: text) {
            guard let image = fontCache.symbolImage(name: symbolName, pointSize: CGFloat(part.font.size)),
                  let entry = atlas.entry(symbolImage: image, cacheKey: "sf:\(symbolName)#\(part.font.size)")
            else { return }
            let originX = (penX * scale).rounded()
            let originY = (partCenterY * scale - CGFloat(entry.sizePx.y) / 2).rounded()
            if let instance = SceneBuilder.glyphInstance(
                origin: SIMD2(Float(originX), Float(originY)),
                entry: entry, color: color, clip: clip) {
                list.glyphs.append(instance)
            }
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
            for index in 0..<count {
                guard let entry = atlas.entry(glyph: glyphs[index], font: runFont) else { continue }
                // Ink-aligned (-inkMinX: ink starts at the pen) with the
                // measurement's rounding slack split evenly — otherwise up to
                // 1.5pt of slack pools on the right and single glyphs (the
                // apple symbol) sit visibly left of center in their pill.
                let glyphPenX = ((penX + positions[index].x - shaped.inkMinX + roundingSlack)
                                 * scale).rounded()
                if let instance = SceneBuilder.glyphInstance(
                    origin: SIMD2(Float(glyphPenX) + entry.bearingPx.x,
                                  Float(baselinePx) + entry.bearingPx.y),
                    entry: entry, color: color, clip: clip) {
                    list.glyphs.append(instance)
                }
            }
        }
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
