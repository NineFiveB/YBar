import AppKit
import Metal

/// Non-activating borderless panel that can never steal focus.
@MainActor
final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// One bar window on one screen: NSPanel → [NSVisualEffectView] → MetalHostView.
/// 100% public API; a SkyLight-backed surface is a planned opt-in alternative
/// behind the same interface.
@MainActor
public final class BarSurface {
    public private(set) var screen: NSScreen
    /// 1-based position in NSScreen.screens (public analogue of sketchybar's adid).
    public let arrangementIndex: Int

    let panel: BarPanel
    let effectView: NSVisualEffectView
    public let hostView: MetalHostView

    /// Item hit-test frames for this surface (bar-local, top-left origin), set after layout.
    public var itemFrames: [(itemID: Int, frame: CGRect)] = []
    public var hoveredItemID: Int?
    /// Per-item glass backdrops keyed by item id: NSGlassEffectView (real
    /// Liquid Glass) on macOS 26+, NSVisualEffectView blur before that.
    private var glassViews: [Int: NSView] = [:]
    /// Host for the native glass views — the contentView of an
    /// NSGlassEffectContainerView, which batches the glass passes and merges
    /// pills that drift within `spacing` of each other. nil pre-26.
    private let glassHost: NSView?
    /// Bar-wide Liquid Glass backdrop (--bar glass=on), behind the pill glass.
    private var barGlass: NSView?
    /// fullscreen_show: temporarily at status level while the active Space
    /// hosts a fullscreen window. Survives apply() until cleared.
    private(set) var elevated = false

    public var onMouse: ((MouseEventInfo, BarSurface) -> Void)?

    public init(screen: NSScreen, arrangementIndex: Int) {
        self.screen = screen
        self.arrangementIndex = arrangementIndex

        panel = BarPanel(
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 25),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        effectView = NSVisualEffectView()
        effectView.blendingMode = .behindWindow
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.autoresizingMask = [.width, .height]

        hostView = MetalHostView(frame: .zero)
        hostView.autoresizingMask = [.width, .height]

        let container = NSView()
        container.autoresizesSubviews = true
        effectView.frame = container.bounds
        hostView.frame = container.bounds
        container.addSubview(effectView)
        // compiler(>=6.2) tracks the macOS 26 SDK: older toolchains lack the
        // NSGlassEffectView symbols entirely, so glass compiles out and the
        // runtime blur fallbacks carry the look.
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let merger = NSGlassEffectContainerView()
            merger.frame = container.bounds
            merger.autoresizingMask = [.width, .height]
            let content = NSView()
            content.frame = merger.bounds
            content.autoresizingMask = [.width, .height]
            merger.contentView = content
            container.addSubview(merger)
            glassHost = content
        } else {
            glassHost = nil
        }
        #else
        glassHost = nil
        #endif
        container.addSubview(hostView)
        panel.contentView = container

        hostView.onMouse = { [weak self] info in
            guard let self else { return }
            self.onMouse?(info, self)
        }
    }

    public var scale: CGFloat { panel.backingScaleFactor }
    public var barSize: CGSize { panel.frame.size }
    /// Panel frame in global AppKit coordinates (for popup anchoring).
    public var panelFrame: CGRect { panel.frame }

    /// Recompute the window frame and appearance from bar settings.
    public func apply(settings: BarSettings, screen: NSScreen) {
        self.screen = screen
        let frame = BarSurface.frame(for: settings, on: screen)
        panel.setFrame(frame, display: true)
        panel.level = elevated ? .statusBar : settings.level.windowLevel
        panel.hasShadow = settings.shadow
        // sticky=off pins the bar to the space it was created on.
        panel.collectionBehavior = settings.sticky
            ? [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            : [.moveToActiveSpace, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            effectView.isHidden = settings.blurRadius <= 0
            if settings.glass, barGlass == nil, let container = panel.contentView {
                let glass = NSGlassEffectView()
                // Clear, same as the pills: regular's frost is an opaque slab
                // at bar width; the bar color quad supplies any tint.
                glass.style = .clear
                glass.appearance = NSAppearance(named: .darkAqua)
                glass.autoresizingMask = [.width, .height]
                glass.frame = container.bounds
                container.addSubview(glass, positioned: .above, relativeTo: effectView)
                barGlass = glass
            }
            barGlass?.isHidden = !settings.glass
            (barGlass as? NSGlassEffectView)?.cornerRadius = CGFloat(settings.cornerRadius)
        } else {
            // Pre-26 there is no glass material; fall back to the blur.
            effectView.isHidden = settings.blurRadius <= 0 && !settings.glass
        }
        #else
        // Old SDK: no glass symbols; the blur is the material.
        effectView.isHidden = settings.blurRadius <= 0 && !settings.glass
        #endif

        effectView.frame = panel.contentView?.bounds ?? .zero
        hostView.frame = panel.contentView?.bounds ?? .zero
        hostView.updateDrawableSize()

        if settings.hidden {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    public func close() {
        panel.orderOut(nil)
        panel.close()
    }

    /// Raise to status level (over a fullscreen window) or restore the
    /// configured level. No-op when the state already matches.
    func setElevated(_ raise: Bool, settings: BarSettings) {
        guard elevated != raise else { return }
        elevated = raise
        panel.level = raise ? .statusBar : settings.level.windowLevel
    }

    /// Sync the per-item glass backdrop views to the latest layout. `rect` is
    /// bar-local top-left-origin points (the painted background pill's rect).
    public func syncGlassBackdrops(_ specs: [(itemID: Int, rect: CGRect, cornerRadius: CGFloat)]) {
        guard let container = panel.contentView else { return }
        let containerHeight = container.bounds.height
        var live = Set<Int>()
        for spec in specs {
            live.insert(spec.itemID)
            // Container is unflipped (AppKit y-up); layout rects are y-down.
            let frame = CGRect(
                x: spec.rect.minX,
                y: containerHeight - spec.rect.maxY,
                width: spec.rect.width,
                height: spec.rect.height)
            var handled = false
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), let glassHost {
                let glass: NSGlassEffectView
                if let existing = glassViews[spec.itemID] as? NSGlassEffectView {
                    glass = existing
                } else {
                    glass = NSGlassEffectView()
                    // Clear glass: fully transparent + refractive (regular's
                    // adaptive frost reads as an opaque dark slab in a bar);
                    // the item's own fill tint supplies the darkness.
                    glass.style = .clear
                    glass.appearance = NSAppearance(named: .darkAqua)
                    glassHost.addSubview(glass)
                    glassViews[spec.itemID] = glass
                }
                glass.frame = frame
                glass.cornerRadius = spec.cornerRadius
                handled = true
            }
            #endif
            if !handled {
                let view: NSVisualEffectView
                if let existing = glassViews[spec.itemID] as? NSVisualEffectView {
                    view = existing
                } else {
                    view = NSVisualEffectView()
                    view.blendingMode = .behindWindow
                    view.material = .hudWindow
                    view.state = .active
                    container.addSubview(view, positioned: .below, relativeTo: hostView)
                    glassViews[spec.itemID] = view
                }
                view.frame = frame
                view.maskImage = BarSurface.roundedMask(radius: spec.cornerRadius)
            }
        }
        for (itemID, view) in glassViews where !live.contains(itemID) {
            view.removeFromSuperview()
            glassViews.removeValue(forKey: itemID)
        }
    }

    /// Stretchable rounded-rect mask (the sanctioned way to shape a
    /// behind-window material), cached per radius.
    private static var maskCache: [Int: NSImage] = [:]
    static func roundedMask(radius: CGFloat) -> NSImage {
        let key = Int(radius.rounded())
        if let cached = maskCache[key] { return cached }
        let edge = max(1, radius * 2 + 1)
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        maskCache[key] = image
        return image
    }

    /// Bar window frame in global AppKit coordinates (bottom-left origin, y-up).
    static func frame(for settings: BarSettings, on screen: NSScreen) -> CGRect {
        let screenFrame = screen.frame
        let width = screenFrame.width - 2 * CGFloat(settings.margin)
        // Notched displays can override height and take an extra offset, so
        // one config sits flush on externals and clears the camera housing
        // on the built-in (sketchybar's notch_display_height/notch_offset).
        let notched = screen.safeAreaInsets.top > 0
        let height = notched && settings.notchDisplayHeight > 0
            ? CGFloat(settings.notchDisplayHeight)
            : CGFloat(settings.height)
        let notchOffset = notched ? CGFloat(settings.notchOffset) : 0
        let x = screenFrame.minX + CGFloat(settings.margin)

        let y: CGFloat
        switch settings.position {
        case .top:
            // sketchybar semantics: the bar owns the top strip whenever the
            // native menu bar is out of the way — covering it (topmost=on) or
            // auto-hidden (the tiling-WM setup: WM top gap + hidden menu bar).
            // Only a visible, persistent menu bar pushes the bar below the
            // strip. On notched displays visibleFrame NEVER includes the strip,
            // so the autohide check must come from defaults, not geometry.
            let topEdge: CGFloat
            if settings.level == .coverMenuBar || BarSurface.menuBarAutohides() {
                topEdge = screenFrame.maxY
            } else {
                topEdge = min(screenFrame.maxY, screen.visibleFrame.maxY)
            }
            y = topEdge - height - CGFloat(settings.yOffset) - notchOffset
        case .bottom:
            y = screenFrame.minY + CGFloat(settings.yOffset) + notchOffset
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The screen's physical notch width in points (0 without a notch).
    static func physicalNotchWidth(of screen: NSScreen) -> CGFloat {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea else { return 0 }
        return max(0, screen.frame.width - left.width - right.width)
    }

    /// Is "Automatically hide and show the menu bar" enabled?
    /// macOS 26+ moved the setting (System Settings > Control Center) to
    /// com.apple.controlcenter's AutoHideMenuBarOption (1 = Always); after the
    /// migration the legacy global-domain `_HIHideMenuBar` is a stale mirror,
    /// so trust the modern key whenever it exists.
    static func menuBarAutohides() -> Bool {
        if let option = UserDefaults(suiteName: "com.apple.controlcenter")?
            .object(forKey: "AutoHideMenuBarOption") as? Int {
            return option == 1
        }
        return UserDefaults.standard
            .persistentDomain(forName: UserDefaults.globalDomain)?["_HIHideMenuBar"] as? Bool ?? false
    }
}
