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

/// One in-flight property animation. A new animation on an animating property
/// RETARGETS it: the in-flight (and any queued) animation is dropped and the
/// new one steers from the current live value. Chaining (sketchybar semantics)
/// piles a full animation onto the queue for every hover enter/exit, so a few
/// pointer sweeps leave items visibly animating for seconds ("stuck").
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
    private var frameTrace = FrameRateTrace()

    /// Provider of a fresh display link bound to a live bar view (wired by the daemon).
    public var makeDisplayLink: ((AnimationScheduler, Selector) -> CADisplayLink?)?
    /// Refresh rates of every display the bar is hosted on (wired by the
    /// daemon). The link asks for the slowest of them, capped at 120 Hz: a
    /// ProMotion panel then samples a frames/60 duration more than once per
    /// sketchybar "frame", while a 60 Hz panel next to it is never fed faster
    /// than it can present. `onFrame` paints every panel, and a layer driven
    /// past its refresh rate fills its three-drawable pool within three ticks,
    /// after which `nextDrawable()` blocks the main thread for the rest of the
    /// slow panel's frame on every tick.
    public var hostRefreshRates: (() -> [Int])?
    /// Called once per animation frame after values are applied and finished
    /// animations have completed. The daemon paints here, on the display-link
    /// callback: the sample is on screen the same turn it was computed, and
    /// the paint retires any coalesced redraw the updates raised on the way.
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
        // Retarget: `from` is the property's current (possibly mid-flight)
        // value, so superseding the existing animation steers smoothly.
        animations[key] = animation
        startLinkIfNeeded()
    }

    /// Cancel any animation on this key (direct sets supersede animations).
    func cancel(key: String) {
        animations.removeValue(forKey: key)
        stopLinkIfIdle()
    }

    /// Cancel every animation under a key namespace — `item.<id>.` when an
    /// item is removed, so its closures stop steering freed component state.
    func cancel(prefix: String) {
        animations = animations.filter { !$0.key.hasPrefix(prefix) }
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
        frameTrace.reset()
        startLinkIfNeeded()
    }

    private func startLinkIfNeeded() {
        guard displayLink == nil, isAnimating || continuousDemand else { return }
        guard let link = makeDisplayLink?(self, #selector(step(_:))) else { return }
        // Set before the link joins the run loop. The request is pinned
        // explicitly rather than left to the link's default range: the
        // slowest hosted panel's rate, floored at 60 and capped at 120.
        // The rates are sampled only here, when a link is (re)created, so a
        // refresh-rate change with no surface rebuild behind it (toggling
        // ProMotion in System Settings) keeps the old range until the next
        // reattachDisplayLink().
        link.preferredFrameRateRange = Self.preferredFrameRateRange(
            hostedHz: hostRefreshRates?() ?? [])
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// The link's requested cadence for a set of hosted panels: the slowest
    /// one, because every tick paints all of them. No panel at all (headless,
    /// or the daemon has not wired the rates) reads as 60.
    static func preferredFrameRateRange(hostedHz: [Int]) -> CAFrameRateRange {
        preferredFrameRateRange(screenHz: hostedHz.min() ?? 60)
    }

    /// The link's requested cadence. Minimum stays 60 so a 60Hz display is
    /// unchanged; the ceiling is 120 even when the panel reports more.
    static func preferredFrameRateRange(screenHz: Int) -> CAFrameRateRange {
        let maximum = Float(min(120, max(60, screenHz)))
        return CAFrameRateRange(minimum: 60, maximum: maximum, preferred: maximum)
    }

    private func stopLinkIfIdle() {
        guard animations.isEmpty, !continuousDemand else { return }
        displayLink?.invalidate()
        displayLink = nil
        frameTrace.reset()
    }

    @objc private func step(_ link: CADisplayLink) {
        tick(now: link.targetTimestamp)
        // After the tick: when this frame finished the last animation the link
        // is already gone and the trace reset, so an idle gap never enters
        // the average.
        if displayLink != nil { traceFrame(link) }
    }

    /// YBAR_DEBUG: the measured animation frame rate, every ~2 s while the
    /// link runs. Counts delivered ticks — CADisplayLink skips a callback
    /// whenever a frame overruns its budget, so this reads the sustained rate
    /// against the link's nominal cadence rather than the cadence itself.
    private func traceFrame(_ link: CADisplayLink) {
        guard DebugTrace.enabled, let fps = frameTrace.record(now: link.targetTimestamp) else { return }
        let nominal = link.duration > 0 ? 1 / link.duration : 0
        DebugTrace.log(String(format: "[ybar:frames] %.1f fps sustained (animation clock, link %.0f Hz)",
                              fps, nominal))
    }

    /// One frame at `now`. Finished keys are removed BEFORE their completions
    /// run: a completion that animates the same key again would otherwise be
    /// swept away together with the animation it replaced. Every applied
    /// value and every completion lands before `onFrame`, so the paint there
    /// sees the whole sample and consumes whatever damage the updates raised.
    func tick(now: TimeInterval) {
        var finished: [(key: String, onComplete: (() -> Void)?)] = []
        for (key, animation) in animations where !animation.tick(now: now) {
            finished.append((key, animation.onComplete))
        }
        for entry in finished { animations.removeValue(forKey: entry.key) }
        for entry in finished { entry.onComplete?() }
        onFrame?()
        stopLinkIfIdle()
    }
}

/// `YBAR_DEBUG` (any value) turns on the stderr diagnostics a bug report can
/// carry: the sustained animation frame rate (`[ybar:frames]`, this file) and
/// per-display geometry on every surface (re)build (`[ybar:display]`,
/// `BarManager.rebuildSurfaces`). Same gate and prefixes as the Windows port.
public enum DebugTrace {
    public static let enabled = ProcessInfo.processInfo.environment["YBAR_DEBUG"] != nil

    public static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}

/// The accumulator behind `[ybar:frames]`: counts display-link ticks and
/// reports frames / elapsed once at least `window` seconds have passed, then
/// opens the next window. Pure, so a test drives it with synthetic
/// timestamps. The first tick after a (re)start only opens the window — a
/// run is never averaged across the idle gap before it.
struct FrameRateTrace {
    let window: TimeInterval
    private(set) var frames = 0
    private(set) var windowStart: TimeInterval?

    init(window: TimeInterval = 2) {
        self.window = window
    }

    /// One tick at `now`; the sustained rate when this tick closes a window.
    mutating func record(now: TimeInterval) -> Double? {
        guard let start = windowStart else {
            windowStart = now
            frames = 0
            return nil
        }
        frames += 1
        let elapsed = now - start
        guard elapsed >= window else { return nil }
        let rate = Double(frames) / elapsed
        windowStart = now
        frames = 0
        return rate
    }

    /// The clock stopped: the next tick opens a fresh window.
    mutating func reset() {
        windowStart = nil
        frames = 0
    }
}
