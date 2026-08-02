import AppKit
import QuartzCore

/// Easing curves. First-letter CLI parsing and the l/q/s/t/e/c set are
/// sketchybar-compatible; bounce/overshoot actually work here (sketchybar
/// reserved the names but fell back to linear).
public enum AnimationCurve: String, Sendable {
    case linear, quadratic, sin, tanh, exp, circ, bounce, overshoot

    public static func parse(_ text: String) -> AnimationCurve {
        switch text.first {
        case "q": return .quadratic
        case "s": return .sin
        case "t": return .tanh
        case "e": return .exp
        case "c": return .circ
        case "b": return .bounce
        case "o": return .overshoot
        default: return .linear
        }
    }

    /// Progress mapping; t in [0,1]. May overshoot 1 for springy curves.
    public func value(_ t: Double) -> Double {
        switch self {
        case .linear:
            return t
        case .quadratic:
            return t * t
        case .sin:
            return Foundation.sin(.pi * t / 2)
        case .tanh:
            // sketchybar's smoothstep-like tanh: 0.52·tanh(2·atanh(1/1.04)·(t−0.5)) + 0.5
            let k = 2 * Foundation.atanh(1 / 1.04)
            return 0.52 * Foundation.tanh(k * (t - 0.5)) + 0.5
        case .exp:
            return t * Foundation.exp(t - 1)
        case .circ:
            return (1 - (t - 1) * (t - 1)).squareRoot()
        case .bounce:
            var t = t
            let n1 = 7.5625, d1 = 2.75
            if t < 1 / d1 { return n1 * t * t }
            if t < 2 / d1 { t -= 1.5 / d1; return n1 * t * t + 0.75 }
            if t < 2.5 / d1 { t -= 2.25 / d1; return n1 * t * t + 0.9375 }
            t -= 2.625 / d1
            return n1 * t * t + 0.984375
        case .overshoot:
            let s = 1.70158
            let u = t - 1
            return 1 + (s + 1) * u * u * u + s * u * u
        }
    }
}

/// A value a property animation can carry.
public enum AnimValue {
    case float(Float)
    case color(YColor)

    static func lerp(_ from: AnimValue, _ to: AnimValue, _ t: Double) -> AnimValue {
        switch (from, to) {
        case let (.float(a), .float(b)):
            return .float(a + (b - a) * Float(t))
        case let (.color(a), .color(b)):
            return .color(YColor.lerp(a, b, Float(t)))
        default:
            return to
        }
    }
}

/// One in-flight property animation. Same-key animations chain sequentially
/// (sketchybar semantics: a new animation on an animating property queues from
/// the previous final value).
@MainActor
final class PropertyAnimation {
    let key: String
    var from: AnimValue
    let to: AnimValue
    let duration: TimeInterval
    let curve: AnimationCurve
    let apply: (AnimValue) -> Void
    /// Runs once when the animation reaches its final value (not on cancel).
    let onComplete: (() -> Void)?
    var startTime: TimeInterval?
    var pending: PropertyAnimation?

    init(key: String, from: AnimValue, to: AnimValue, duration: TimeInterval,
         curve: AnimationCurve, apply: @escaping (AnimValue) -> Void,
         onComplete: (() -> Void)? = nil) {
        self.key = key
        self.from = from
        self.to = to
        self.duration = duration
        self.curve = curve
        self.apply = apply
        self.onComplete = onComplete
    }

    /// Advance to `now`; returns false when finished (final value applied).
    func tick(now: TimeInterval) -> Bool {
        if startTime == nil { startTime = now }
        let elapsed = now - startTime!
        guard duration > 0, elapsed < duration else {
            apply(to)
            return false
        }
        let t = curve.value(elapsed / duration)
        apply(AnimValue.lerp(from, to, t))
        return true
    }
}

/// Owns the display link (running only while animations exist) and the
/// animation table. Durations arrive in frames-at-60Hz (sketchybar CLI compat).
@MainActor
public final class AnimationScheduler {
    private var animations: [String: PropertyAnimation] = [:]
    private var displayLink: CADisplayLink?

    /// Provider of a fresh display link bound to a live bar view (wired by the daemon).
    public var makeDisplayLink: ((AnimationScheduler, Selector) -> CADisplayLink?)?
    /// Called once per animation frame after values are applied.
    public var onFrame: (() -> Void)?

    public init() {}

    public var isAnimating: Bool { !animations.isEmpty }

    /// Keeps the display link alive with zero property animations (marquee
    /// text): each frame still fires onFrame so the scene re-encodes.
    public var continuousDemand = false {
        didSet {
            if continuousDemand { startLinkIfNeeded() } else { stopLinkIfIdle() }
        }
    }

    func animate(key: String, from: AnimValue, to: AnimValue,
                 durationFrames: Int, curve: AnimationCurve,
                 apply: @escaping (AnimValue) -> Void,
                 onComplete: (() -> Void)? = nil) {
        let duration = TimeInterval(durationFrames) / 60.0
        let animation = PropertyAnimation(
            key: key, from: from, to: to, duration: duration, curve: curve,
            apply: apply, onComplete: onComplete)
        if let existing = animations[key] {
            // Chain after the last queued animation, starting from its target.
            var tail = existing
            while let next = tail.pending { tail = next }
            animation.from = tail.to
            tail.pending = animation
        } else {
            animations[key] = animation
            startLinkIfNeeded()
        }
    }

    /// Cancel any animation on this key (direct sets supersede animations).
    func cancel(key: String) {
        animations.removeValue(forKey: key)
        stopLinkIfIdle()
    }

    public func cancelAll() {
        animations.removeAll()
        stopLinkIfIdle()
    }

    /// The link host went away (surface rebuild); re-arm against the new host.
    public func reattachDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        startLinkIfNeeded()
    }

    private func startLinkIfNeeded() {
        guard displayLink == nil, isAnimating || continuousDemand else { return }
        guard let link = makeDisplayLink?(self, #selector(step(_:))) else { return }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopLinkIfIdle() {
        guard animations.isEmpty, !continuousDemand else { return }
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        var finishedKeys: [String] = []
        for (key, animation) in animations {
            if !animation.tick(now: now) {
                animation.onComplete?()
                if let next = animation.pending {
                    animations[key] = next
                } else {
                    finishedKeys.append(key)
                }
            }
        }
        finishedKeys.forEach { animations.removeValue(forKey: $0) }
        onFrame?()
        stopLinkIfIdle()
    }
}
