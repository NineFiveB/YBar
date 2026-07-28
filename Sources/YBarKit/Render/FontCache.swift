import AppKit
import CoreText

/// Shaped-line + font caches. Status-bar strings repeat heavily, so both caches
/// have generous hit rates; they are cleared wholesale when they grow too large.
@MainActor
public final class FontCache {
    public struct ShapedLine {
        public let line: CTLine
        public let width: CGFloat
        public let ascent: CGFloat
        public let descent: CGFloat
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
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let shaped = ShapedLine(line: line, width: width, ascent: ascent, descent: descent)
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

    /// Measured size of one text part (layout units, points).
    public func measure(part: TextPart) -> CGSize {
        let text = part.displayString
        guard !text.isEmpty else { return .zero }
        if let symbolName = FontCache.sfSymbolName(in: text) {
            guard let image = symbolImage(name: symbolName, pointSize: CGFloat(part.font.size)) else {
                return .zero
            }
            return image.size
        }
        let shaped = shapedLine(text: text, spec: part.font)
        return CGSize(width: ceil(shaped.width), height: ceil(shaped.ascent + shaped.descent))
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
