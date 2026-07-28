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
        container.addSubview(hostView)
        panel.contentView = container

        hostView.onMouse = { [weak self] info in
            guard let self else { return }
            self.onMouse?(info, self)
        }
    }

    public var scale: CGFloat { panel.backingScaleFactor }
    public var barSize: CGSize { panel.frame.size }

    /// Recompute the window frame and appearance from bar settings.
    public func apply(settings: BarSettings, screen: NSScreen) {
        self.screen = screen
        let frame = BarSurface.frame(for: settings, on: screen)
        panel.setFrame(frame, display: true)
        panel.level = settings.level.windowLevel
        effectView.isHidden = settings.blurRadius <= 0

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

    /// Bar window frame in global AppKit coordinates (bottom-left origin, y-up).
    static func frame(for settings: BarSettings, on screen: NSScreen) -> CGRect {
        let screenFrame = screen.frame
        let width = screenFrame.width - 2 * CGFloat(settings.margin)
        let height = CGFloat(settings.height)
        let x = screenFrame.minX + CGFloat(settings.margin)

        let y: CGFloat
        switch settings.position {
        case .top:
            // Below the native menu bar when it is visible and the bar does not
            // cover it; at the very top otherwise (visibleFrame tracks autohide).
            let topEdge: CGFloat
            if settings.level == .coverMenuBar {
                topEdge = screenFrame.maxY
            } else {
                topEdge = min(screenFrame.maxY, screen.visibleFrame.maxY)
            }
            y = topEdge - height - CGFloat(settings.yOffset)
        case .bottom:
            y = screenFrame.minY + CGFloat(settings.yOffset)
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
