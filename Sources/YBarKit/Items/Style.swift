import AppKit
import simd

/// ARGB color, sketchybar-compatible (`0xAARRGGBB` literals on the CLI).
/// Stored as straight-alpha float components in sRGB.
public struct YColor: Equatable, Sendable {
    public var alpha: Float
    public var red: Float
    public var green: Float
    public var blue: Float

    public init(alpha: Float = 0, red: Float = 0, green: Float = 0, blue: Float = 0) {
        self.alpha = alpha
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(argb: UInt32) {
        alpha = Float((argb >> 24) & 0xFF) / 255
        red = Float((argb >> 16) & 0xFF) / 255
        green = Float((argb >> 8) & 0xFF) / 255
        blue = Float(argb & 0xFF) / 255
    }

    public var argb: UInt32 {
        func channel(_ value: Float) -> UInt32 { UInt32((max(0, min(1, value)) * 255).rounded()) }
        return channel(alpha) << 24 | channel(red) << 16 | channel(green) << 8 | channel(blue)
    }

    /// Parse `0xAARRGGBB` (or a plain integer). Returns nil on malformed input.
    public static func parse(_ string: String) -> YColor? {
        var text = string.lowercased()
        var radix = 10
        if text.hasPrefix("0x") {
            text = String(text.dropFirst(2))
            radix = 16
        }
        guard let value = UInt32(text, radix: radix) else { return nil }
        return YColor(argb: value)
    }

    /// Straight-alpha RGBA for GPU consumption, with RGB linearized: the render
    /// target is `bgra8Unorm_srgb`, so shaders and blending operate in linear
    /// light and the hardware encodes on store (correct gradient midpoints and
    /// AA coverage — the artifact class the architecture doc calls out).
    public var simd: SIMD4<Float> {
        SIMD4(YColor.toLinear(red), YColor.toLinear(green), YColor.toLinear(blue), alpha)
    }

    static func toLinear(_ c: Float) -> Float {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    static func toGamma(_ c: Float) -> Float {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
    }

    /// Interpolate in linear light — avoids sketchybar's per-byte ARGB lerp
    /// with its off-hue midpoints.
    public static func lerp(_ from: YColor, _ to: YColor, _ t: Float) -> YColor {
        func mix(_ a: Float, _ b: Float) -> Float { a + (b - a) * t }
        return YColor(
            alpha: mix(from.alpha, to.alpha),
            red: toGamma(mix(toLinear(from.red), toLinear(to.red))),
            green: toGamma(mix(toLinear(from.green), toLinear(to.green))),
            blue: toGamma(mix(toLinear(from.blue), toLinear(to.blue)))
        )
    }

    public static let clear = YColor(argb: 0x0000_0000)
    public static let white = YColor(argb: 0xFFFF_FFFF)
}

/// Hard-offset silhouette shadow (sketchybar semantics: distance + angle, no blur).
/// A gaussian soft shadow is a planned extension (`blur` field reserved).
public struct ShadowStyle: Equatable, Sendable {
    public var drawing: Bool = false
    public var color: YColor = YColor(argb: 0xFF00_0000)
    public var distance: Float = 5
    public var angle: Float = 30

    public init() {}

    public var offset: CGSize {
        let radians = angle * .pi / 180
        return CGSize(width: CGFloat(cos(radians) * distance), height: CGFloat(sin(radians) * distance))
    }
}

/// Rounded-rect background: fill, optional 2-stop gradient, border, shadow.
public struct BackgroundStyle: Equatable, Sendable {
    public var drawing: Bool = false
    public var color: YColor = .clear
    /// When set, a linear gradient from `color` to `gradientColor` along `gradientAngle` degrees.
    public var gradientColor: YColor?
    public var gradientAngle: Float = 0
    public var borderColor: YColor = .clear
    public var borderWidth: Float = 0
    public var cornerRadius: Float = 0
    /// Superellipse exponent: 2 = circular corners, ~4.5 ≈ Apple continuous ("squircle").
    public var cornerExponent: Float = 2
    public var height: Float = 0
    public var paddingLeft: Float = 0
    public var paddingRight: Float = 0
    public var xOffset: Float = 0
    public var yOffset: Float = 0
    public var shadow = ShadowStyle()

    public init() {}
}

/// One text part of an item (`icon.*` or `label.*` on the CLI).
public struct TextPart: Equatable, Sendable {
    public var string: String = ""
    public var drawing: Bool = true
    public var color: YColor = .white
    public var highlight: Bool = false
    public var highlightColor: YColor = .clear
    public var font = FontSpec()
    public var paddingLeft: Float = 0
    public var paddingRight: Float = 0
    public var yOffset: Float = 0
    public var maxChars: Int = 0
    /// Fixed width override (-1 = natural width). Content aligns per `align`
    /// and clips to the box — the substrate of sketchybar's hover-reveal idiom
    /// (`label.width` animating 0 ↔ dynamic).
    public var customWidth: Float = -1
    /// Content alignment within a fixed width: l/c/r.
    public var align: Character = "l"
    public var background = BackgroundStyle()
    public var shadow = ShadowStyle()

    public init() {}

    public var effectiveColor: YColor { highlight ? highlightColor : color }

    /// Text truncated to `maxChars` unicode scalars (0 = unlimited).
    public var displayString: String {
        guard maxChars > 0, string.count > maxChars else { return string }
        return String(string.prefix(maxChars)) + "…"
    }
}

/// Font specification parsed from the sketchybar-compatible "Family:Style:Size" form.
public struct FontSpec: Equatable, Hashable, Sendable {
    public var family: String = ""
    public var style: String = ""
    public var size: Float = 14

    public init() {}

    /// Parse "Family:Style:Size"; missing components keep current values.
    public mutating func apply(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 1, !parts[0].isEmpty { family = parts[0] }
        if parts.count >= 2, !parts[1].isEmpty { style = parts[1] }
        if parts.count >= 3, let value = Float(parts[2]) { size = value }
    }

    public var description: String { "\(family):\(style):\(String(format: "%.1f", size))" }
}

/// Position slots along the bar. `centerLeft`/`centerRight` (sketchybar `q`/`e`)
/// flow away from the notch dead zone. `.popup` items live in a host item's
/// popup panel (the host name is `Item.popupHost`).
public enum ItemPosition: String, Sendable {
    case left, right, center
    case centerLeft = "q"
    case centerRight = "e"
    case popup = "p"

    public static func parse(_ text: String) -> ItemPosition? {
        switch text {
        case "left", "l": return .left
        case "right", "r": return .right
        case "center", "c": return .center
        case "q", "center_left": return .centerLeft
        case "e", "center_right": return .centerRight
        default: return nil
        }
    }
}

/// When an item's script runs on the routine timer.
public enum UpdatePolicy: String, Sendable {
    case on, off, whenShown = "when_shown"
}
