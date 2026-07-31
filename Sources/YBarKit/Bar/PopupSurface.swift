import AppKit
import Metal

/// Anchored popup panel for one host item: a small Metal surface at pop-up-menu
/// level, positioned against the host's bar frame. Same renderer, own scene.
@MainActor
public final class PopupSurface {
    public let hostItemID: Int
    let panel: BarPanel
    public let hostView: MetalHostView

    /// Popup-local hit frames (top-left origin, points).
    public var itemFrames: [(itemID: Int, frame: CGRect)] = []
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

        hostView = MetalHostView(frame: .zero)
        hostView.autoresizingMask = [.width, .height]
        hostView.metalLayer.device = device
        panel.contentView = hostView

        hostView.onMouse = { [weak self] info in
            guard let self else { return }
            self.onMouse?(info, self)
        }
    }

    public var scale: CGFloat { max(panel.backingScaleFactor, 1) }

    /// Place and show the panel. `anchor` is the host item's frame in global
    /// AppKit coordinates (bottom-left origin, y-up); the popup hangs below it
    /// for a top bar and sits above it for a bottom bar.
    public func present(anchor: CGRect, size: CGSize, barPosition: BarPosition, yOffset: CGFloat) {
        let frame: CGRect
        switch barPosition {
        case .top:
            frame = CGRect(
                x: anchor.minX,
                y: anchor.minY - size.height - yOffset,
                width: size.width,
                height: size.height)
        case .bottom:
            frame = CGRect(
                x: anchor.minX,
                y: anchor.maxY + yOffset,
                width: size.width,
                height: size.height)
        }
        panel.setFrame(frame, display: true)
        hostView.updateDrawableSize()
        panel.orderFrontRegardless()
    }

    public func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
