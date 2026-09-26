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

/// Bar behavior on a fullscreen Space (`fullscreen_show` / `fullscreen_hide`).
public enum FullscreenPolicy: Equatable, Sendable {
    /// Carried onto the Space at the configured level: covered by the
    /// fullscreen window unless `topmost=on` already clears it. The default.
    case carry
    /// Carried and raised to status level over the fullscreen window.
    case raise
    /// Not carried onto fullscreen Spaces at all.
    case hide
}

/// Where the glass rim reads the backdrop it refracts.
///
/// Refraction needs a picture of what is behind the bar, and the Metal layer
/// draws OVER the system material without ever reading it — so the source has
/// to come from outside the renderer. There are only two, and they trade
/// accuracy against a permission prompt.
public enum RefractionMode: String, Sendable, CaseIterable {
    /// No backdrop sampling. The rim keeps its own per-channel dispersion,
    /// which needs no source at all. The default: nothing prompts, nothing
    /// captures.
    case off
    /// ScreenCaptureKit, filtered to the bar's own strip with YBar's windows
    /// excluded. Correct over any window. The ONLY value that can raise the
    /// Screen Recording prompt — and it raises it because someone typed it.
    case screen
    /// The desktop picture, used only while no window sits under the strip.
    /// No permission, no capture, and a static texture — but it is a lie the
    /// moment a window reaches the top of the screen, so it steps aside then.
    case wallpaper
    /// `screen` when Screen Recording has ALREADY been granted, `wallpaper`
    /// while the desktop is what is behind, `off` otherwise. Never prompts:
    /// it takes what is already available and asks for nothing.
    case auto
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
    /// NSGlassEffectView material. Default `clear`.
    public var glassVariant: GlassVariant = .clear
    /// `NSGlassEffectView.tintColor` for the bar strip and the default for
    /// pills that do not set `background.glass_tint`. Alpha is intensity
    /// (System Settings Liquid Glass slider). Clear leaves the material untinted.
    public var glassTint: YColor = .clear
    /// Auto-raise to status level while the active Space hosts a fullscreen
    /// window, so the bar stays visible over native-fullscreen Spaces
    /// (fullScreenAuxiliary already carries the panel onto them; only the
    /// window level needs to clear the fullscreen window's).
    public var fullscreenShow: Bool = false
    /// Opt-in native hide-in-fullscreen: keep the bar, popup and tooltip
    /// panels off fullscreen Spaces altogether (no fullScreenAuxiliary), so
    /// the WindowServer hides them there with no polling. Wins over
    /// `fullscreenShow` — a panel that is not on the Space cannot be raised
    /// over it. Off by default so `topmost=on` keeps drawing over fullscreen
    /// as documented.
    public var fullscreenHide: Bool = false
    public var hidden: Bool = false
    public var level: BarLevel = .behindWindows
    public var sticky: Bool = true
    /// Native window shadow under the whole bar (sketchybar --bar shadow).
    public var shadow: Bool = false
    /// Display-sleep inhibition active (--bar idle_inhibit).
    public var idleInhibit: Bool = false
    public var displayPolicy: DisplayPolicy = .all
    /// Width of the notch dead zone separating centerLeft/centerRight flows
    /// on notched displays (un-notched displays get no dead zone). 0 =
    /// auto-detect the physical notch width from the screen's auxiliary
    /// top areas.
    public var notchWidth: Float = 200
    /// Additional y offset applied only on notched displays (sketchybar
    /// parity) — lets one config sit flush on externals and drop below the
    /// camera housing on the built-in.
    public var notchOffset: Float = 0
    /// Bar height override on notched displays; 0 = use `height`.
    public var notchDisplayHeight: Float = 0
    /// Backdrop source for chromatic refraction at the glass rim.
    public var refraction: RefractionMode = .off

    public init() {}

    /// What the panels do while the active Space hosts a fullscreen window.
    /// Pure so the policy can be pinned headlessly: `hide` is the only state
    /// that changes a panel's collection behavior, and the only one the
    /// three shipped keyless configs must never land in by default.
    public var fullscreenPolicy: FullscreenPolicy {
        if fullscreenHide { return .hide }
        return fullscreenShow ? .raise : .carry
    }

    /// Should a bar exist on the display with this 1-based arrangement index?
    public func includesDisplay(arrangementIndex: Int, isMain: Bool) -> Bool {
        switch displayPolicy {
        case .all: return true
        case .main: return isMain
        case .list(let indices): return indices.contains(arrangementIndex)
        }
    }
}
