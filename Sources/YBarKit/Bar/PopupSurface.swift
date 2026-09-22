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
    /// Label-plate glass, under the Metal layer. nil before macOS 26.
    private let chipHost: NSView?
    private var chipViews: [Int: NSView] = [:]
    public var onMouse: ((MouseEventInfo, PopupSurface) -> Void)?

    /// Bumped on every visibility edge (present, fadeOut, close). A fade's
    /// completion compares its own generation and stands down when a later
    /// edge — a reopen mid-fade, a rebuild's close() — has superseded it.
    private var fadeGeneration = 0
    /// A fade-out is in flight: the panel is still on screen at falling
    /// alpha and deaf to the mouse. Cleared by the next present() (a reopen
    /// mid-fade ramps back up) or by the ramp's own close().
    public private(set) var isClosing = false
    public var isVisible: Bool { panel.isVisible }

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
        panel.collectionBehavior = BarSurface.collectionBehavior(sticky: true, policy: .carry)

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
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = true
            }
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
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let merger = NSGlassEffectContainerView()
            merger.frame = container.bounds
            merger.autoresizingMask = [.width, .height]
            // 0 keeps each button its own capsule. The default spacing would
            // melt a Connect pill into the row beside it.
            merger.spacing = 0
            let content = NSView()
            content.frame = merger.bounds
            content.autoresizingMask = [.width, .height]
            merger.contentView = content
            container.addSubview(merger)
            chipHost = content
        } else {
            chipHost = nil
        }
        #else
        chipHost = nil
        #endif
        container.addSubview(hostView)
        panel.contentView = container

        hostView.onMouse = { [weak self] info in
            guard let self else { return }
            self.onMouse?(info, self)
        }
    }

    public var scale: CGFloat { max(panel.backingScaleFactor, 1) }

    /// fullscreen_hide: a popup or tooltip stays off fullscreen Spaces with
    /// its bar. Carried there on its own it would float over the fullscreen
    /// window at menu level with no bar to hang from (scripts can open a
    /// popup without a click).
    var hidesInFullscreen = false {
        didSet {
            guard hidesInFullscreen != oldValue else { return }
            panel.collectionBehavior = BarSurface.collectionBehavior(
                sticky: true, policy: hidesInFullscreen ? .hide : .carry)
        }
    }

    /// Place and show the panel. `anchor` is the host item's frame in global
    /// AppKit coordinates (bottom-left origin, y-up); the popup hangs below it
    /// for a top bar and sits above it for a bottom bar. `align` anchors the
    /// panel's left/center/right edge against the host. The panel is kept
    /// inside `screen` horizontally, `edgeMargin` short of its edges.
    public func present(anchor: CGRect, size: CGSize, barPosition: BarPosition,
                        yOffset: CGFloat, align: Character,
                        screen: NSScreen, edgeMargin: CGFloat,
                        fadeInFrames: CGFloat = 0) {
        let frame = PopupSurface.frame(
            anchor: anchor, size: size, barPosition: barPosition, yOffset: yOffset,
            align: align, screenFrame: screen.frame, edgeMargin: edgeMargin)
        panel.setFrame(frame, display: true)
        backdropView.frame = panel.contentView?.bounds ?? .zero
        hostView.frame = panel.contentView?.bounds ?? .zero
        hostView.updateDrawableSize()
        // Fade only on the hidden→shown edge: present() runs on every render
        // pass while the popup is open, and restarting the ramp each time
        // would keep the panel from ever finishing appearing. A reopen
        // mid-fade-out is an edge too (the Windows port re-arms it through
        // hide()): the ramp restarts from 0 — the intended pop — and the
        // abandoned fade-out's completion is retired by the generation bump.
        guard !panel.isVisible || isClosing else {
            panel.orderFrontRegardless()
            return
        }
        fadeGeneration += 1
        isClosing = false
        panel.ignoresMouseEvents = false
        guard fadeInFrames > 0 else {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        // On screen at alpha 0, so the frame ordered in before the scene has
        // rendered into it is never seen.
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(fadeInFrames / 60)
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            panel.animator().alphaValue = 1
        }
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

    /// Place an `NSGlassEffectView` under each glass label plate. `rect` is
    /// popup-local, top-left origin. Views sit under the Metal layer, so the
    /// translucent fill and the label text stay on top. Missing chips are
    /// removed.
    public func syncGlassChips(_ chips: [SceneBuilder.PopupScene.GlassChip]) {
        #if compiler(>=6.2)
        guard #available(macOS 26.0, *), let chipHost else { return }
        let bounds = panel.contentView?.bounds ?? .zero
        if let merger = chipHost.superview {
            merger.frame = bounds
            chipHost.frame = merger.bounds
        }
        let height = bounds.height
        var live = Set<Int>()
        for chip in chips {
            // Last plate for an item wins (the label is emitted after the icon).
            live.insert(chip.itemID)
            let frame = CGRect(
                x: chip.rect.minX,
                y: height - chip.rect.maxY,
                width: chip.rect.width,
                height: chip.rect.height)
            let glass: NSGlassEffectView
            if let existing = chipViews[chip.itemID] as? NSGlassEffectView {
                glass = existing
            } else {
                glass = NSGlassEffectView()
                glass.appearance = NSAppearance(named: .darkAqua)
                chipHost.addSubview(glass)
                chipViews[chip.itemID] = glass
            }
            glass.frame = frame
            glass.cornerRadius = chip.cornerRadius
            // Clear, not regular: a frosted slab at button size hides the tint.
            BarSurface.configureLiquidGlass(glass, variant: .clear, tint: chip.tint)
            glass.isHidden = false
        }
        for (itemID, view) in chipViews where !live.contains(itemID) {
            view.removeFromSuperview()
            chipViews.removeValue(forKey: itemID)
        }
        #else
        _ = chips
        #endif
    }

    /// Glass behind the whole panel (popup.blur_radius > 0). `tint` is the
    /// popup override or the bar's `glass_tint` (alpha is intensity).
    public func setGlass(enabled: Bool, cornerRadius: CGFloat, tint: YColor = .clear) {
        backdropView.isHidden = !enabled
        guard enabled else { return }
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = backdropView as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
            glass.tintColor = tint.nsColor
            return
        }
        #endif
        if let effect = backdropView as? NSVisualEffectView {
            effect.maskImage = BarSurface.roundedMask(radius: cornerRadius)
        }
    }

    /// Start the close ramp (popup.fade_out). The panel stays on screen, deaf
    /// to the mouse, until the ramp ends; then it orders out and `completion`
    /// runs on the main actor. The owner keeps the surface alive until then.
    /// A present() in the meantime reopens it and the completion never fires.
    public func fadeOut(frames: CGFloat, completion: @escaping @MainActor () -> Void) {
        guard !isClosing else { return }
        guard frames > 0, panel.isVisible else {
            close()
            completion()
            return
        }
        fadeGeneration += 1
        let generation = fadeGeneration
        isClosing = true
        // Deaf at once, or the dismissing click lands in a ghost.
        panel.ignoresMouseEvents = true
        let duration = TimeInterval(frames / 60)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .linear)
            panel.animator().alphaValue = 0
        }
        // The hide is a one-shot timer a frame past the ramp's end, as in the
        // Windows port (its 109687f): the ramp runs on the window server with
        // this process rendering nothing, so nothing else would come back to
        // order the panel out until the next render — a clock tick, a hover,
        // seconds later — and a shown panel at zero alpha still casts its
        // shadow. A timer, not the animation group's completion: that is
        // delivered with the transaction's own completion and never arrives
        // in a process whose run loop is not serving Core Animation (the
        // headless tests), while the main queue always drains.
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 1 / 60) { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            self.close()
            completion()
        }
    }

    public func close() {
        // Retire an in-flight fade: its completion must neither order out a
        // panel that was reopened nor run the owner's teardown twice.
        fadeGeneration += 1
        isClosing = false
        panel.ignoresMouseEvents = false
        panel.alphaValue = 1
        panel.orderOut(nil)
        panel.close()
    }
}
