import AppKit
import CoreText

/// Shaped-line + font caches. Status-bar strings repeat heavily, so both caches
/// have generous hit rates; overflowing one evicts half of it.
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
    /// The value is itself optional: a name AppKit cannot resolve is cached as
    /// nil, or an `sf:` typo re-enters AppKit on every measurement of every
    /// frame — a miss costs ~15 us against ~0.07 us for a hit, and a part is
    /// measured several times per frame.
    private var symbolImages: [String: NSImage?] = [:]
    /// Unresolvable symbol names already named on stderr; the part renders
    /// blank and said nothing about why.
    private var reportedMissingSymbols: Set<String> = []
    /// How often AppKit was actually asked to resolve a symbol. A part is
    /// measured several times per frame, so every one of these that is not a
    /// genuine first sighting is ~15 us of the frame's budget spent again.
    private(set) var symbolResolutions = 0

    /// Cache bounds. Both values are small (a CTLine and its metrics, a
    /// configured NSImage), so the bounds are generous; what matters is that
    /// overflowing evicts HALF rather than everything — wiping the whole
    /// table made the next frame re-shape every string on the bar.
    private static let lineLimit = 4096
    private static let symbolLimit = 1024

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
        if lines.count >= FontCache.lineLimit { FontCache.evictHalf(&lines) }

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
        let width = FontCache.layoutWidth(ink: pathBounds.width)
        let shaped = ShapedLine(
            line: line, width: width, ascent: ascent, descent: descent,
            inkWidth: pathBounds.width,
            inkMinX: pathBounds.minX, inkMinY: pathBounds.minY, inkMaxY: pathBounds.maxY)
        lines[key] = shaped
        return shaped
    }

    /// SF Symbol image for `sf:<name>` strings, configured at the part's font
    /// size. The size arrives already quantized (FontSpec.quantize), so the
    /// key matches the atlas key for the same lookup and an animated size
    /// mints a bounded number of entries rather than one per frame.
    public func symbolImage(name: String, pointSize: CGFloat) -> NSImage? {
        let key = "\(name)#\(pointSize)"
        if let cached = symbolImages[key] { return cached }
        if symbolImages.count >= FontCache.symbolLimit { FontCache.evictHalf(&symbolImages) }
        symbolResolutions += 1
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        let resolved = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        // The failure is cached too: the name is a config typo or a symbol
        // this macOS does not have, and neither resolves by trying again.
        symbolImages[key] = resolved
        if resolved == nil, reportedMissingSymbols.insert(name).inserted {
            FileHandle.standardError.write(Data(
                "[!] sf:\(name) is not a symbol on this system, nothing to draw\n".utf8))
        }
        return resolved
    }

    /// Drop half the entries when a cache hits its bound. Which half is
    /// arbitrary (a dictionary has no order), but half an arbitrary cache
    /// beats all of a good one.
    private static func evictHalf<Key, Value>(_ cache: inout [Key: Value]) {
        for key in cache.keys.prefix(cache.count / 2) { cache.removeValue(forKey: key) }
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
        reportedMissingSymbols.removeAll()
    }

    /// sketchybar's text_get_length: the tight ink width truncated as
    /// `(int)(width + 1.5)` — truncated, not rounded, so 10.0 becomes 11 and
    /// 10.5 becomes 12. Every padding and alignment in a ported config
    /// depends on this exact table (the port pins the same formula), and it
    /// never goes negative or traps on a degenerate line.
    nonisolated public static func layoutWidth(ink: CGFloat) -> CGFloat {
        guard ink.isFinite else { return 0 }
        return CGFloat(max(0, Int(ink + 1.5)))
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
