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
    /// Applied to bar strip and pill glass on the next sync / apply.
    private var glassVariant: GlassVariant = .clear
    /// Bar-wide `NSGlassEffectView` tint. Pills inherit this unless overridden.
    private var glassTint: YColor = .clear
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
            // 0 keeps each pill a separate glass object. The default spacing
            // melts neighbors into one blob, so a highlight slides across the
            // row instead of staying inside the pill it belongs to.
            merger.spacing = 0
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
        panel.collectionBehavior = BarSurface.collectionBehavior(
            sticky: settings.sticky, policy: settings.fullscreenPolicy)
        glassVariant = settings.glassVariant
        glassTint = settings.glassTint
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            effectView.isHidden = settings.blurRadius <= 0
            if settings.glass, barGlass == nil, let container = panel.contentView {
                let glass = NSGlassEffectView()
                glass.appearance = NSAppearance(named: .darkAqua)
                glass.autoresizingMask = [.width, .height]
                glass.frame = container.bounds
                BarSurface.configureLiquidGlass(
                    glass, variant: settings.glassVariant, tint: settings.glassTint)
                container.addSubview(glass, positioned: .above, relativeTo: effectView)
                barGlass = glass
            }
            barGlass?.isHidden = !settings.glass
            if let glass = barGlass as? NSGlassEffectView {
                glass.cornerRadius = CGFloat(settings.cornerRadius)
                BarSurface.configureLiquidGlass(
                    glass, variant: settings.glassVariant, tint: settings.glassTint)
            }
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

    /// Collection behavior for a bar or popup panel. sticky=off pins the bar
    /// to the space it was created on. The hide policy leaves out
    /// fullScreenAuxiliary, the flag that carries a panel onto fullscreen
    /// Spaces: without it the WindowServer keeps the panel off them by
    /// itself — no polling, no private API — and shows it again on the way
    /// out. Every other policy keeps the flag, so the raise-only default is
    /// untouched.
    static func collectionBehavior(sticky: Bool, policy: FullscreenPolicy) -> NSWindow.CollectionBehavior {
        var behavior: NSWindow.CollectionBehavior = sticky
            ? [.canJoinAllSpaces, .stationary, .ignoresCycle]
            : [.moveToActiveSpace, .stationary, .ignoresCycle]
        if policy != .hide { behavior.insert(.fullScreenAuxiliary) }
        return behavior
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
    /// `variantOverride` is per-item (`background.glass_variant`); nil uses the
    /// bar-wide setting. Metal text/icons stay siblings of the glass (not in
    /// `contentView`) so the existing glyph pipeline keeps working — AppKit
    /// only guarantees z-order for `contentView` children.
    public func syncGlassBackdrops(
        _ specs: [(itemID: Int, rect: CGRect, cornerRadius: CGFloat, variant: GlassVariant?, tint: YColor?)],
        lensCoversPills: Bool = false
    ) {
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
            let variant = spec.variant ?? glassVariant
            let tint = spec.tint ?? glassTint
            var handled = false
            #if compiler(>=6.2)
            if #available(macOS 26.0, *), let glassHost {
                let glass: NSGlassEffectView
                if let existing = glassViews[spec.itemID] as? NSGlassEffectView {
                    glass = existing
                } else {
                    glass = NSGlassEffectView()
                    glass.appearance = NSAppearance(named: .darkAqua)
                    glassHost.addSubview(glass)
                    glassViews[spec.itemID] = glass
                }
                glass.frame = frame
                glass.cornerRadius = spec.cornerRadius
                BarSurface.configureLiquidGlass(glass, variant: variant, tint: tint)
                // System glass is the product backdrop; hide only while a
                // ScreenCaptureKit lens texture is actively covering the pills.
                glass.isHidden = lensCoversPills
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
                view.isHidden = lensCoversPills
            }
        }
        for (itemID, view) in glassViews where !live.contains(itemID) {
            view.removeFromSuperview()
            glassViews.removeValue(forKey: itemID)
        }
    }

    /// Public style + interactive flag; optional private `_setVariant:` for
    /// Dock / Control Center approximations. Does not (and cannot) force the
    /// active material on a non-key panel.
    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    static func configureLiquidGlass(
        _ glass: NSGlassEffectView, variant: GlassVariant, tint: YColor = .clear
    ) {
        switch variant {
        case .regular:
            glass.style = .regular
        case .clear, .dock, .controlCenter, .appIcons:
            // Clear: fully transparent + refractive. Regular's adaptive frost
            // reads as an opaque dark slab at bar/pill size; Metal fill tints.
            glass.style = .clear
        }
        glass.tintColor = tint.nsColor
        // compiler(>=6.4) tracks the macOS 27 SDK the way compiler(>=6.2)
        // tracks 26: effectIsInteractive is API_AVAILABLE(macos(27.0)), and an
        // #available check alone cannot save a symbol the SDK does not have.
        #if compiler(>=6.4)
        if #available(macOS 27.0, *) {
            glass.effectIsInteractive = true
        }
        #endif
        if let code = variant.privateVariantCode {
            let sel = Selector(("_setVariant:"))
            if glass.responds(to: sel) {
                glass.perform(sel, with: NSNumber(value: code))
            }
        }
    }
    #endif

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
