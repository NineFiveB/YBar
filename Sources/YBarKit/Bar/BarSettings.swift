import AppKit

/// Bar Z-band, mirroring sketchybar's `topmost` triad.
public enum BarLevel: String, Sendable {
    /// Behind app windows (kCGBackstopMenuLevel, -20) — visible because windows
    /// avoid the menu-bar strip. sketchybar's default; unobtrusive.
    case behindWindows = "off"
    /// Above normal windows (floating level).
    case aboveWindows = "window"
    /// Status-bar level (25) — covers the native menu bar.
    case coverMenuBar = "on"

    public var windowLevel: NSWindow.Level {
        switch self {
        case .behindWindows: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.backstopMenu)))
        case .aboveWindows: return .floating
        case .coverMenuBar: return .statusBar
        }
    }
}

public enum BarPosition: String, Sendable {
    case top, bottom
}

/// Which displays carry a bar.
public enum DisplayPolicy: Equatable, Sendable {
    case all
    case main
    /// Arrangement indices, 1-based.
    case list([Int])
}

/// Global bar configuration (`--bar` domain).
public struct BarSettings: Sendable {
    public var position: BarPosition = .top
    public var height: Float = 25
    public var margin: Float = 0
    public var yOffset: Float = 0
    public var paddingLeft: Float = 0
    public var paddingRight: Float = 0
    public var backgroundColor = YColor(argb: 0x4400_0000)
    public var gradientColor: YColor?
    public var gradientAngle: Float = 0
    public var borderColor: YColor = .clear
    public var borderWidth: Float = 0
    public var cornerRadius: Float = 0
    public var cornerExponent: Float = 2
    /// 0 disables the system blur material behind the bar.
    public var blurRadius: Float = 0
    /// Liquid-glass sheen/rim on the bar background quad.
    public var glass: Bool = false
    public var hidden: Bool = false
    public var level: BarLevel = .behindWindows
    public var sticky: Bool = true
    /// Native window shadow under the whole bar (sketchybar --bar shadow).
    public var shadow: Bool = false
    /// Display-sleep inhibition active (--bar idle_inhibit).
    public var idleInhibit: Bool = false
    public var displayPolicy: DisplayPolicy = .all
    /// Width of the notch dead zone separating centerLeft/centerRight flows.
    /// Auto-detected from safe-area insets when 0 on a notched display.
    public var notchWidth: Float = 200
    public var notchOffset: Float = 0

    public init() {}

    /// Should a bar exist on the display with this 1-based arrangement index?
    public func includesDisplay(arrangementIndex: Int, isMain: Bool) -> Bool {
        switch displayPolicy {
        case .all: return true
        case .main: return isMain
        case .list(let indices): return indices.contains(arrangementIndex)
        }
    }
}
