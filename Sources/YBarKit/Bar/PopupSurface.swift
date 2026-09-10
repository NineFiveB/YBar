import AppKit
import Metal

/// Anchored popup panel for one host item: a small Metal surface at pop-up-menu
/// level, positioned against the host's bar frame. Same renderer, own scene.
@MainActor
public final class PopupSurface {
    public let hostItemID: Int
    let panel: BarPanel
    /// NSGlassEffectView (real Liquid Glass) on macOS 26+, blur fallback before.
    let backdropView: NSView
    public let hostView: MetalHostView

    /// Popup-local hit frames (top-left origin, points).
    public var itemFrames: [(itemID: Int, frame: CGRect)] = []
    public var hoveredItemID: Int?
    public var onMouse: ((MouseEventInfo, PopupSurface) -> Void)?

    public init(hostItemID: Int, device: MTLDevice) {
        self.hostItemID = hostItemID
        panel = BarPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        var madeGlass: NSView?
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            // Regular (frosted) glass, matching system menus/popovers: a popup
            // spans content-rich windows, and clear glass over text lets every
            // line bleed through sharply. The pills stay clear — they float
            // over the wallpaper strip where nothing bleeds.
            glass.style = .regular
            glass.appearance = NSAppearance(named: .darkAqua)
            madeGlass = glass
        }
        #endif
        if let madeGlass {
            backdropView = madeGlass
        } else {
            let effect = NSVisualEffectView()
            effect.blendingMode = .behindWindow
            effect.material = .hudWindow
            effect.state = .active
            backdropView = effect
        }
        backdropView.autoresizingMask = [.width, .height]
        backdropView.isHidden = true

        hostView = MetalHostView(frame: .zero)
        hostView.autoresizingMask = [.width, .height]
        hostView.metalLayer.device = device

        let container = NSView()
        container.autoresizesSubviews = true
        container.addSubview(backdropView)
        container.addSubview(hostView)
        panel.contentView = container

        hostView.onMouse = { [weak self] info in
            guard let self else { return }
            self.onMouse?(info, self)
        }
    }

    public var scale: CGFloat { max(panel.backingScaleFactor, 1) }

    /// Place and show the panel. `anchor` is the host item's frame in global
    /// AppKit coordinates (bottom-left origin, y-up); the popup hangs below it
    /// for a top bar and sits above it for a bottom bar. `align` anchors the
    /// panel's left/center/right edge against the host. The panel is kept
    /// inside `screen` horizontally, `edgeMargin` short of its edges.
    public func present(anchor: CGRect, size: CGSize, barPosition: BarPosition,
                        yOffset: CGFloat, align: Character,
                        screen: NSScreen, edgeMargin: CGFloat) {
        let frame = PopupSurface.frame(
            anchor: anchor, size: size, barPosition: barPosition, yOffset: yOffset,
            align: align, screenFrame: screen.frame, edgeMargin: edgeMargin)
        panel.setFrame(frame, display: true)
        backdropView.frame = panel.contentView?.bounds ?? .zero
        hostView.frame = panel.contentView?.bounds ?? .zero
        hostView.updateDrawableSize()
        panel.orderFrontRegardless()
    }

    /// Panel frame for `present`. A borderless non-activating panel keeps
    /// whatever frame it is given, so an item near a screen edge would push
    /// a centred 320 pt popup onto the neighbouring display or off the
    /// desktop entirely. Clamp the right edge first, then the left: a popup
    /// wider than the screen then lands on the left margin and overflows to
    /// the right instead of being shoved off-screen to the left.
    ///
    /// No vertical correction: the popup only overshoots the far edge when
    /// it is taller than the space beyond the bar, and any vertical move
    /// would then land it over its own host and swallow the clicks meant
    /// for it (the Windows port's flip is a no-op in that case for the same
    /// reason).
    static func frame(anchor: CGRect, size: CGSize, barPosition: BarPosition,
                      yOffset: CGFloat, align: Character,
                      screenFrame: CGRect, edgeMargin: CGFloat) -> CGRect {
        var x: CGFloat
        switch align {
        case "c": x = anchor.midX - size.width / 2
        case "r": x = anchor.maxX - size.width
        default: x = anchor.minX
        }
        x = min(x, screenFrame.maxX - edgeMargin - size.width)
        x = max(x, screenFrame.minX + edgeMargin)
        let y: CGFloat
        switch barPosition {
        case .top: y = anchor.minY - size.height - yOffset
        case .bottom: y = anchor.maxY + yOffset
        }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// Glass behind the whole panel (popup.blur_radius > 0).
    public func setGlass(enabled: Bool, cornerRadius: CGFloat) {
        backdropView.isHidden = !enabled
        guard enabled else { return }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backdropView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            return
        }
        #endif
        if let effect = backdropView as? NSVisualEffectView {
            effect.maskImage = BarSurface.roundedMask(radius: cornerRadius)
        }
    }

    public func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
