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
    /// It is handed the frame's presentation time — the link's
    /// `targetTimestamp`, the same clock the property animations interpolate
    /// against — so everything in one frame is sampled at one instant.
    public var onFrame: ((TimeInterval) -> Void)?

    public init() {}

    public var isAnimating: Bool { !animations.isEmpty }

    /// Item IDs with a property animation in flight, parsed from the live
    /// animation keys (`item.<id>.<property>`, the shape every item property
    /// animation is registered under). Derived on demand rather than kept as
    /// a counted set: a retarget replaces a key in place and `cancel(prefix:)`
    /// drops a whole namespace, so a maintained tally would have to mirror
    /// both, while reading the table cannot fall out of step with it.
    public var animatingItemIDs: Set<Int> {
        var ids: Set<Int> = []
        for key in animations.keys where key.hasPrefix("item.") {
            let rest = key.dropFirst(5)
            guard let dot = rest.firstIndex(of: "."),
                  let id = Int(rest[rest.startIndex..<dot]) else { continue }
            ids.insert(id)
        }
        return ids
    }

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
        // The rates are sampled only here, whenever a link is created —
        // after an idle teardown (stopLinkIfIdle) or reattachDisplayLink()
        // — so a refresh-rate change while a link is running (toggling
        // ProMotion in System Settings mid-animation) is not picked up
        // until then.
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
        // The whole tick is timed, not just the interpolation: `onFrame` is
        // called from inside it, so this one number covers renderAll, the
        // scene build, the glass sync, nextDrawable and the present — the
        // number that says whether the requested cadence is sustainable.
        let began = DebugTrace.enabled ? CACurrentMediaTime() : 0
        tick(now: link.targetTimestamp)
        // After the tick: when this frame finished the last animation the link
        // is already gone and the trace reset, so an idle gap never enters
        // the average.
        if displayLink != nil {
            traceFrame(link, cost: DebugTrace.enabled ? CACurrentMediaTime() - began : 0)
        }
    }

    /// YBAR_DEBUG: what the animation clock actually delivered, every ~2 s
    /// while the link runs. The sustained rate alone cannot tell a smooth 120
    /// from a juddering one — it counts delivered ticks and divides by
    /// elapsed, so two callbacks 4.0 ms and 12.6 ms apart average to exactly
    /// 120.0 and read as perfect — so the line also carries the arbitrated
    /// cadence, the vsyncs the clock skipped, the worst gap between
    /// callbacks, what a tick cost against its budget, and how many of those
    /// ticks actually put a different picture on screen.
    private func traceFrame(_ link: CADisplayLink, cost: TimeInterval) {
        guard DebugTrace.enabled,
              let report = frameTrace.record(now: link.targetTimestamp,
                                             interval: link.duration, cost: cost)
        else { return }
        let render = RenderTrace.drain()
        DebugTrace.log(String(
            format: "[ybar:frames] %.1f fps sustained (link %.0f Hz), %d missed, "
                + "max gap %.1f ms, tick p99 %.2f ms / %.2f ms, %d/%d frames changed",
            report.fps, report.linkHz, report.missed, report.maxGap * 1000,
            report.p99Cost * 1000, report.budget * 1000,
            render.changed, render.presents))
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
        onFrame?(now)
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
/// reports the window once at least `window` seconds have passed, then opens
/// the next one. Pure, so a test drives it with synthetic timestamps. The
/// first tick after a (re)start only opens the window — a run is never
/// averaged across the idle gap before it.
struct FrameRateTrace {
    /// One closed window.
    struct Report {
        let fps: Double
        /// The cadence Core Animation actually arbitrated, from the link's
        /// own `duration`. A request of 60–120 can be answered with 60 at any
        /// moment, and only this number says which answer we got.
        let linkHz: Double
        /// Vsyncs the clock skipped: a callback two intervals after the last
        /// one missed exactly one. Counted against the PREVIOUS tick's
        /// interval, because on a variable-rate panel `duration` tracks the
        /// arbitrated cadence and would silently re-baseline the very moment
        /// the link degrades.
        let missed: Int
        let maxGap: TimeInterval
        /// What a whole tick (interpolation, layout, scene build, present)
        /// cost, against the interval it had to fit in.
        let p99Cost: TimeInterval
        let budget: TimeInterval
    }

    let window: TimeInterval
    private(set) var frames = 0
    private(set) var windowStart: TimeInterval?
    private var lastTick: TimeInterval?
    private var lastInterval: TimeInterval = 0
    private var missed = 0
    private var gaps: [TimeInterval] = []
    private var costs: [TimeInterval] = []

    init(window: TimeInterval = 2) {
        self.window = window
    }

    /// One tick at `now`, delivered on a link whose current cadence is
    /// `interval` and whose whole body cost `cost`; the window's numbers when
    /// this tick closes it.
    @discardableResult
    mutating func record(now: TimeInterval, interval: TimeInterval = 0,
                         cost: TimeInterval = 0) -> Report? {
        guard let start = windowStart, let previous = lastTick else {
            open(at: now, interval: interval)
            return nil
        }
        // A cadence change (ProMotion arbitrating down, Low Power Mode) makes
        // every rate in the window mean two different things, so it opens a
        // fresh one instead of averaging across it.
        if lastInterval > 0, interval > 0, abs(interval - lastInterval) > lastInterval * 0.05 {
            open(at: now, interval: interval)
            return nil
        }
        frames += 1
        let gap = now - previous
        gaps.append(gap)
        costs.append(cost)
        if lastInterval > 0 {
            missed += max(0, Int((gap / lastInterval).rounded()) - 1)
        }
        lastTick = now
        lastInterval = interval > 0 ? interval : lastInterval

        let elapsed = now - start
        guard elapsed >= window else { return nil }
        let report = Report(
            fps: Double(frames) / elapsed,
            linkHz: lastInterval > 0 ? 1 / lastInterval : 0,
            missed: missed,
            maxGap: gaps.max() ?? 0,
            p99Cost: FrameRateTrace.percentile(costs, 0.99),
            budget: lastInterval)
        open(at: now, interval: interval)
        return report
    }

    /// The clock stopped: the next tick opens a fresh window.
    mutating func reset() {
        open(at: nil, interval: 0)
        lastInterval = 0
    }

    private mutating func open(at now: TimeInterval?, interval: TimeInterval) {
        windowStart = now
        lastTick = now
        if interval > 0 { lastInterval = interval }
        frames = 0
        missed = 0
        gaps.removeAll(keepingCapacity: true)
        costs.removeAll(keepingCapacity: true)
    }

    static func percentile(_ values: [TimeInterval], _ fraction: Double) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1,
                        max(0, Int((Double(sorted.count - 1) * fraction).rounded())))
        return sorted[index]
    }
}

/// Render-side counters the `[ybar:frames]` line reads. A frame that is
/// byte-identical to the one before it was presented for nothing: the panel
/// refreshed and the picture did not change, which is exactly what pixel
/// snapping produces when a motion's per-frame step is under a device pixel.
/// `[ybar:frames]` cannot see that on its own — such a frame still counts as
/// delivered — so the renderer reports it. Only maintained under YBAR_DEBUG.
@MainActor
enum RenderTrace {
    private(set) static var presents = 0
    private(set) static var changed = 0
    private static var lastFrameHash: [ObjectIdentifier: Int] = [:]

    /// One present of `hash` into `layer`; whether it differs from that
    /// layer's previous frame.
    static func present(layer: AnyObject, hash: Int) {
        presents += 1
        let key = ObjectIdentifier(layer)
        if lastFrameHash.updateValue(hash, forKey: key) != hash { changed += 1 }
    }

    /// Read the counts and open the next window. The per-layer hashes survive
    /// it — they describe what is on screen — so only the counts restart.
    static func drain() -> (presents: Int, changed: Int) {
        defer {
            presents = 0
            changed = 0
        }
        return (presents, changed)
    }
}
