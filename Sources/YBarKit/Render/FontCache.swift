import AppKit
import CoreText

/// Shaped-line + font caches. Status-bar strings repeat heavily, so both caches
/// have generous hit rates; they are cleared wholesale when they grow too large.
@MainActor
public final class FontCache {
    public struct ShapedLine {
        public let line: CTLine
        /// sketchybar-compatible width: tight glyph-path bounds with its
        /// `(int)(width + 1.5)` rounding — the value all spacing derives from.
        public let width: CGFloat
        public let ascent: CGFloat
        public let descent: CGFloat
        /// Raw (unrounded) ink width — the rounding slack (width - inkWidth)
        /// is distributed evenly so glyphs sit dead-center in their box.
        public let inkWidth: CGFloat
        /// Ink-box left edge in text space: drawing shifts by -inkMinX so the
        /// ink starts exactly at the pen and left/right paddings are equal.
        public let inkMinX: CGFloat
        /// Ink-box vertical extent relative to the baseline (y-up) — used to
        /// ink-center single-glyph icon parts.
        public let inkMinY: CGFloat
        public let inkMaxY: CGFloat
    }

    private struct LineKey: Hashable {
        let text: String
        let font: FontSpec
    }

    private var fonts: [FontSpec: CTFont] = [:]
    private var lines: [LineKey: ShapedLine] = [:]
    private var symbolImages: [String: NSImage] = [:]

    public init() {}

    public func font(for spec: FontSpec) -> CTFont {
        if let cached = fonts[spec] { return cached }
        let font = FontCache.makeFont(spec: spec)
        fonts[spec] = font
        return font
    }

    public func shapedLine(text: String, spec: FontSpec) -> ShapedLine {
        let key = LineKey(text: text, font: spec)
        if let cached = lines[key] { return cached }
        if lines.count > 1024 { lines.removeAll(keepingCapacity: true) }

        let font = self.font(for: spec)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        // sketchybar measures ink, not advances (text.c): glyph-path bounds
        // with (int)(width + 1.5). Advances run wider and unevenly so.
        let pathBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let width = CGFloat(Int(pathBounds.width + 1.5))
        let shaped = ShapedLine(
            line: line, width: width, ascent: ascent, descent: descent,
            inkWidth: pathBounds.width,
            inkMinX: pathBounds.minX, inkMinY: pathBounds.minY, inkMaxY: pathBounds.maxY)
        lines[key] = shaped
        return shaped
    }

    /// SF Symbol image for `sf:<name>` strings, configured at the part's font size.
    public func symbolImage(name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)#\(pointSize)"
        if let cached = symbolImages[key] { return cached }
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        guard let configured = base.withSymbolConfiguration(configuration) else { return nil }
        symbolImages[key] = configured
        return configured
    }

    /// Measured ink size of one text part (layout units, points). Fixed-width
    /// slot semantics (customWidth with paddings folded INSIDE, sketchybar's
    /// text_get_length override) are applied by Layout.partAdvance and
    /// SceneBuilder — not here.
    public func measure(part: TextPart) -> CGSize {
        naturalMeasure(part: part)
    }

    /// Natural (unclamped) size of the part's content.
    public func naturalMeasure(part: TextPart) -> CGSize {
        let text = part.displayString
        guard !text.isEmpty else { return .zero }
        if let symbolName = FontCache.sfSymbolName(in: text) {
            guard let image = symbolImage(name: symbolName, pointSize: CGFloat(part.font.size)) else {
                return .zero
            }
            return image.size
        }
        let shaped = shapedLine(text: text, spec: part.font)
        return CGSize(width: shaped.width, height: ceil(shaped.ascent + shaped.descent))
    }

    public func clear() {
        fonts.removeAll()
        lines.removeAll()
        symbolImages.removeAll()
    }

    /// `sf:wifi` → "wifi"; nil for ordinary text.
    public static func sfSymbolName(in text: String) -> String? {
        guard text.hasPrefix("sf:"), text.count > 3 else { return nil }
        return String(text.dropFirst(3))
    }

    static func makeFont(spec: FontSpec) -> CTFont {
        let size = CGFloat(spec.size)
        if spec.family.isEmpty {
            let weight = FontCache.systemWeight(for: spec.style)
            return NSFont.systemFont(ofSize: size, weight: weight)
        }
        var attributes: [CFString: Any] = [
            kCTFontFamilyNameAttribute: spec.family,
            kCTFontSizeAttribute: size,
        ]
        if !spec.style.isEmpty {
            attributes[kCTFontStyleNameAttribute] = spec.style
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    static func systemWeight(for style: String) -> NSFont.Weight {
        switch style.lowercased() {
        case "ultralight": return .ultraLight
        case "thin": return .thin
        case "light": return .light
        case "medium": return .medium
        case "semibold": return .semibold
        case "bold": return .bold
        case "heavy": return .heavy
        case "black": return .black
        default: return .regular
        }
    }
}
