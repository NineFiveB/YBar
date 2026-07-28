import AppKit
import CoreText
import simd

/// Traverses the item tree + layout result into a flat, paint-ordered DisplayList
/// in device pixels. Paint order: bar background → per item (shadow, background,
/// icon, label). Re-encoding the full bar every dirty frame is microseconds; damage
/// tracking gates *whether* a frame renders, never what is drawn.
@MainActor
public final class SceneBuilder {
    let fontCache: FontCache

    public init(fontCache: FontCache) {
        self.fontCache = fontCache
    }

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
        list.quads.append(barQuad)

        for item in items {
            guard item.isVisible, let contentBox = contentBoxes[item.id], contentBox.width > 0 || item.customWidth >= 0 else { continue }
            emit(item: item, contentBox: contentBox, barSize: barSize, scale: scale, atlas: atlas, into: &list)
        }

        return list
    }

    private func emit(
        item: Item,
        contentBox: CGRect,
        barSize: CGSize,
        scale: CGFloat,
        atlas: GlyphAtlas,
        into list: inout DisplayList
    ) {
        let iconSize = fontCache.measure(part: item.icon)
        let labelSize = fontCache.measure(part: item.label)
        let contentHeight = max(iconSize.height, labelSize.height)
        // y_offset is positive-up (sketchybar convention); our coordinates are y-down.
        let centerY = barSize.height / 2 - CGFloat(item.yOffset)

        // Background + shadow.
        if item.background.drawing {
            let backgroundHeight = item.background.height > 0
                ? CGFloat(item.background.height)
                : min(barSize.height, contentHeight + 8)
            let backgroundRect = CGRect(
                x: contentBox.minX + CGFloat(item.background.xOffset),
                y: centerY - backgroundHeight / 2 - CGFloat(item.background.yOffset),
                width: contentBox.width,
                height: backgroundHeight)
            let radius = Float(item.background.cornerRadius) * Float(scale)
            let radii = SIMD4<Float>(repeating: radius)

            if item.background.shadow.drawing {
                let offset = item.background.shadow.offset
                let shadowRect = backgroundRect.offsetBy(dx: offset.width, dy: -offset.height)
                list.quads.append(QuadInstance(
                    origin: SceneBuilder.pixelOrigin(shadowRect, scale: scale),
                    size: SceneBuilder.pixelSize(shadowRect, scale: scale),
                    radii: radii,
                    fill: item.background.shadow.color.simd))
            }

            var quad = QuadInstance(
                origin: SceneBuilder.pixelOrigin(backgroundRect, scale: scale),
                size: SceneBuilder.pixelSize(backgroundRect, scale: scale),
                radii: radii,
                fill: item.background.color.simd,
                borderWidth: item.background.borderWidth * Float(scale),
                cornerExponent: item.background.cornerExponent,
                borderColor: item.background.borderColor.simd)
            if let gradient = item.background.gradientColor {
                quad.fill2 = gradient.simd
                quad.gradientDir = SceneBuilder.gradientDirection(angleDegrees: item.background.gradientAngle)
                quad.flags |= QuadInstance.flagGradient
            }
            list.quads.append(quad)
        }

        // Fixed-width alignment slack.
        var penX = contentBox.minX
        if item.customWidth >= 0 {
            var natural: CGFloat = 0
            if item.icon.drawing, !item.icon.string.isEmpty {
                natural += CGFloat(item.icon.paddingLeft) + iconSize.width + CGFloat(item.icon.paddingRight)
            }
            if item.label.drawing, !item.label.string.isEmpty {
                natural += CGFloat(item.label.paddingLeft) + labelSize.width + CGFloat(item.label.paddingRight)
            }
            let slack = max(0, CGFloat(item.customWidth) - natural)
            switch item.align {
            case "c": penX += slack / 2
            case "r": penX += slack
            default: break
            }
        }

        // Icon, then label.
        if item.icon.drawing, !item.icon.string.isEmpty {
            penX += CGFloat(item.icon.paddingLeft)
            emitText(part: item.icon, penX: penX, centerY: centerY,
                     scale: scale, atlas: atlas, into: &list)
            penX += iconSize.width + CGFloat(item.icon.paddingRight)
        }
        if item.label.drawing, !item.label.string.isEmpty {
            penX += CGFloat(item.label.paddingLeft)
            emitText(part: item.label, penX: penX, centerY: centerY,
                     scale: scale, atlas: atlas, into: &list)
        }
        // TODO(v1.5): per-part backgrounds (icon.background.* / label.background.*).
    }

    private func emitText(
        part: TextPart,
        penX: CGFloat,
        centerY: CGFloat,
        scale: CGFloat,
        atlas: GlyphAtlas,
        into list: inout DisplayList
    ) {
        let text = part.displayString
        guard !text.isEmpty else { return }
        let color = part.effectiveColor.simd
        let partCenterY = centerY - CGFloat(part.yOffset)

        if let symbolName = FontCache.sfSymbolName(in: text) {
            guard let image = fontCache.symbolImage(name: symbolName, pointSize: CGFloat(part.font.size)),
                  let entry = atlas.entry(symbolImage: image, cacheKey: "sf:\(symbolName)#\(part.font.size)")
            else { return }
            let originX = (penX * scale).rounded()
            let originY = (partCenterY * scale - CGFloat(entry.sizePx.y) / 2).rounded()
            list.glyphs.append(GlyphInstance(
                origin: SIMD2(Float(originX), Float(originY)),
                size: entry.sizePx,
                uvOrigin: entry.uvOrigin,
                uvSize: entry.uvSize,
                color: color,
                flags: entry.isColor ? GlyphInstance.flagColorGlyph : 0))
            return
        }

        let shaped = fontCache.shapedLine(text: text, spec: part.font)
        let baselineY = partCenterY + (shaped.ascent - shaped.descent) / 2
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

            for index in 0..<count {
                guard let entry = atlas.entry(glyph: glyphs[index], font: runFont) else { continue }
                let glyphPenX = ((penX + positions[index].x) * scale).rounded()
                list.glyphs.append(GlyphInstance(
                    origin: SIMD2(Float(glyphPenX) + entry.bearingPx.x,
                                  Float(baselinePx) + entry.bearingPx.y),
                    size: entry.sizePx,
                    uvOrigin: entry.uvOrigin,
                    uvSize: entry.uvSize,
                    color: color,
                    flags: entry.isColor ? GlyphInstance.flagColorGlyph : 0))
            }
        }
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
