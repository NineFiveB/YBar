import AppKit
import CoreGraphics

/// Is a screen recording running? macOS shows the purple StatusIndicator
/// at the top right while one is, and it draws that ABOVE every window —
/// a bar that covers the menu bar gets it painted over its last pill. There
/// is no notification for it and no public API that answers the question,
/// but the indicator is a real window, and the window list gives its owner,
/// layer and bounds without Screen Recording (only titles and pixels need
/// the grant). So this polls the list — cheaply, and only while something
/// has subscribed — and emits `recording_change` when the answer changes.
///
/// Event contract: INFO = "on" | "off"; env RECORDING = the same,
/// RECORDING_X / RECORDING_WIDTH / RECORDING_HEIGHT = the indicator's frame in
/// screen points (top-left origin) while on, so a theme can make room for it
/// exactly where it is rather than guessing.
@MainActor
public final class RecordingIndicatorProvider {
    public var onChange: ((_ frame: CGRect?) -> Void)?

    private var timer: DispatchSourceTimer?
    private var last: CGRect?
    private var seeded = false

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start(interval: TimeInterval = 1.5) {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// One read of the window list. Emits only on change — and once at
    /// start, so a subscriber learns the current answer without waiting for
    /// it to flip.
    public func poll() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        let frame = Self.indicatorFrame(in: list)
        if seeded && frame == last { return }
        seeded = true
        last = frame
        onChange?(frame)
    }

    /// The indicator among the on-screen windows, or nil. Matched by what
    /// the list gives without a grant: the WindowServer as owner, a layer far
    /// above anything an app can reach, a small square, and the top strip.
    /// Measured on macOS 27: owner "Window Server", layer 2147483630, 28×28
    /// at y=3. The name ("StatusIndicator") would be the cleanest key, but
    /// names come back empty without Screen Recording — and a bar that had
    /// the grant would not need this file to notice a recording.
    nonisolated public static func indicatorFrame(in windows: [[String: Any]]) -> CGRect? {
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "Window Server",
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer > 1_000_000,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  y < 44, w <= 40, h <= 40, abs(w - h) <= 4
            else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }
}
