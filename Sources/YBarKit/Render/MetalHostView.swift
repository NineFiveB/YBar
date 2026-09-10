import AppKit
import QuartzCore

public enum MouseEventKind {
    case down
    case dragged
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

/// Turns trackpad scrolling into wheel-style steps. A wheel notch arrives as
/// one non-precise event carrying whole lines (scrollingDeltaY 1.0 per notch,
/// measured on this toolchain) and is forwarded as-is. A trackpad instead
/// delivers a stream of precise, pixel-sized samples at the sensor rate, and
/// forwarding each one fired `mouse.scrolled` dozens of times per swipe —
/// the shipped volume helper steps 4 % per event. AppKit's own legacy
/// mapping (deltaY = scrollingDeltaY / 10 for precise devices, measured)
/// treats 10 pt as one line, so that is the step: accumulate per gesture and
/// emit the signed number of whole steps crossed, at most once per sample.
struct ScrollStepper {
    static let pointsPerStep: CGFloat = 10
    private var accumulated: CGFloat = 0

    /// Delta to forward for one sample, or nil to swallow it.
    mutating func delta(scrollingDeltaY: CGFloat, precise: Bool, gestureBegan: Bool) -> CGFloat? {
        guard precise else { return scrollingDeltaY }
        // A new gesture must not inherit the tail of the previous one.
        if gestureBegan { accumulated = 0 }
        accumulated += scrollingDeltaY
        let steps = (accumulated / ScrollStepper.pointsPerStep).rounded(.towardZero)
        guard steps != 0 else { return nil }
        accumulated -= steps * ScrollStepper.pointsPerStep
        return steps
    }
}

/// Layer-hosting NSView owning the CAMetalLayer, forwarding mouse interaction.
/// Flipped so view coordinates match the bar's top-left-origin layout space.
@MainActor
public final class MetalHostView: NSView {
    public let metalLayer = CAMetalLayer()
    public var onMouse: ((MouseEventInfo) -> Void)?
    private var scrollStepper = ScrollStepper()
    /// Fired when backingScaleFactor changes (window moved across displays) —
    /// the owner must schedule a corrective frame at the new scale.
    public var onBackingChanged: (() -> Void)?

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
        onBackingChanged?()
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

    public override func mouseDown(with event: NSEvent) { forward(event, kind: .down, button: "left") }
    public override func mouseDragged(with event: NSEvent) { forward(event, kind: .dragged, button: "left") }
    public override func mouseUp(with event: NSEvent) { forward(event, kind: .clicked, button: "left") }
    public override func rightMouseUp(with event: NSEvent) { forward(event, kind: .clicked, button: "right") }
    public override func otherMouseUp(with event: NSEvent) { forward(event, kind: .clicked, button: "other") }
    public override func mouseMoved(with event: NSEvent) { forward(event, kind: .moved) }
    public override func mouseEntered(with event: NSEvent) { forward(event, kind: .moved) }
    public override func mouseExited(with event: NSEvent) { forward(event, kind: .exited) }
    public override func scrollWheel(with event: NSEvent) {
        guard let delta = scrollStepper.delta(
            scrollingDeltaY: event.scrollingDeltaY,
            precise: event.hasPreciseScrollingDeltas,
            gestureBegan: event.phase == .began) else { return }
        forward(event, kind: .scrolled, scrollDelta: delta)
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
