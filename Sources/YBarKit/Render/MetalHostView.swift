import AppKit
import QuartzCore

public enum MouseEventKind {
    case clicked
    case moved
    case exited
    case scrolled
}

public struct MouseEventInfo {
    public let kind: MouseEventKind
    /// Bar-local point, top-left origin, points.
    public let point: CGPoint
    /// "left" | "right" | "other" for clicks.
    public let button: String
    /// "shift" | "ctrl" | "alt" | "cmd" | "none"
    public let modifier: String
    public let scrollDelta: CGFloat
}

/// Layer-hosting NSView owning the CAMetalLayer, forwarding mouse interaction.
/// Flipped so view coordinates match the bar's top-left-origin layout space.
@MainActor
public final class MetalHostView: NSView {
    public let metalLayer = CAMetalLayer()
    public var onMouse: ((MouseEventInfo) -> Void)?

    public override var isFlipped: Bool { true }
    public override var wantsUpdateLayer: Bool { true }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .duringViewResize
        layerContentsPlacement = .topLeft
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.maximumDrawableCount = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override func makeBackingLayer() -> CALayer { metalLayer }

    // MARK: - Backing / size

    public func updateDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2.0
        metalLayer.contentsScale = scale
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        if size.width > 0, size.height > 0, metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
    }

    public override func layout() {
        super.layout()
        updateDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDrawableSize()
    }

    // MARK: - Mouse

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self,
            userInfo: nil))
    }

    public override func mouseUp(with event: NSEvent) { forward(event, kind: .clicked, button: "left") }
    public override func rightMouseUp(with event: NSEvent) { forward(event, kind: .clicked, button: "right") }
    public override func otherMouseUp(with event: NSEvent) { forward(event, kind: .clicked, button: "other") }
    public override func mouseMoved(with event: NSEvent) { forward(event, kind: .moved) }
    public override func mouseEntered(with event: NSEvent) { forward(event, kind: .moved) }
    public override func mouseExited(with event: NSEvent) { forward(event, kind: .exited) }
    public override func scrollWheel(with event: NSEvent) {
        forward(event, kind: .scrolled, scrollDelta: event.scrollingDeltaY)
    }

    private func forward(
        _ event: NSEvent,
        kind: MouseEventKind,
        button: String = "left",
        scrollDelta: CGFloat = 0
    ) {
        let point = convert(event.locationInWindow, from: nil)
        onMouse?(MouseEventInfo(
            kind: kind,
            point: point,
            button: button,
            modifier: MetalHostView.modifierName(event.modifierFlags),
            scrollDelta: scrollDelta))
    }

    static func modifierName(_ flags: NSEvent.ModifierFlags) -> String {
        if flags.contains(.shift) { return "shift" }
        if flags.contains(.control) { return "ctrl" }
        if flags.contains(.option) { return "alt" }
        if flags.contains(.command) { return "cmd" }
        return "none"
    }
}
