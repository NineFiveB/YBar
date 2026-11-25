import AppKit
import CoreGraphics

/// One display's recording indicator, in that display's own points.
public struct RecordingIndicator: Equatable, Sendable {
    /// 1-based arrangement index: `arrangement-id` in `--query displays`,
    /// the N of `bounding_rects["display-N"]`.
    public let display: Int
    /// The indicator window from its display's top-left corner, y down.
    public let frame: CGRect

    public init(display: Int, frame: CGRect) {
        self.display = display
        self.frame = frame
    }
}

/// The indicator sits in the top strip of ITS display, not of the desktop.
private let topStrip: CGFloat = 44
/// The cursor window always contains the pointer; the slack covers the two
/// reads (window list, pointer) not being one.
private let pointerSlack: CGFloat = 12
/// Larger than any cursor image, enlarged pointer included; smaller than the
/// WindowServer's other overlays on the indicator's layer (a notch cover).
private let cursorLimit: CGFloat = 256

/// Is a screen recording running? macOS shows the purple StatusIndicator
/// at the top right while one is, and it draws that ABOVE every window —
/// a bar that covers the menu bar gets it painted over its last pill. There
/// is no notification for it and no public API that answers the question,
/// but the indicator is a real window, and the window list gives its owner,
/// layer and bounds without Screen Recording (only titles and pixels need
/// the grant). So this polls the list — cheaply, and only while something
/// has subscribed — and emits `recording_change` when the answer changes.
///
/// macOS draws one indicator on EVERY display, and a display can sit
/// anywhere on the desktop — a Sidecar to the left of the main display has
/// its indicator at a negative desktop x. So each indicator is resolved to
/// the display it is on and reported in that display's own points; a number
/// in desktop coordinates means nothing to a bar that lives on one display.
///
/// Event contract: INFO = "on" | "off"; env RECORDING = the same. While on:
/// RECORDING_FRAMES = one `<display>:<x>,<y>,<w>,<h>` per display showing an
/// indicator, space separated, ascending by display — `<display>` is the
/// arrangement id (`--query displays`, the N of `bounding_rects["display-N"]`)
/// and the frame is the indicator window in that display's points (top-left
/// origin, y down; it may be negative or overhang the edge).
/// RECORDING_DISPLAY names the lowest-numbered display showing one, and
/// RECORDING_X / RECORDING_Y / RECORDING_WIDTH / RECORDING_HEIGHT are that
/// display's entry — with a single display, exactly the indicator's frame on
/// screen. The event is said again after a config reload and after the bars
/// are rebuilt, so a widget fitted to it never keeps a stale answer.
@MainActor
public final class RecordingIndicatorProvider {
    public var onChange: ((_ indicators: [RecordingIndicator]) -> Void)?

    private var timer: DispatchSourceTimer?
    private var last: [RecordingIndicator] = []
    private var seeded = false
    private var republishSerial = 0

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start(interval: TimeInterval = 1.5) {
        // Already polling: a reload re-subscribed, and the new subscriber is
        // owed the answer the old one already had.
        guard timer == nil else { republish(); return }
        seeded = false
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

    /// Say the current answer again, changed or not. Deferred, never
    /// immediate: a subscriber measures it against laid-out bars, and those
    /// exist only after the render that follows a rebuild or a reload.
    /// Requests inside the delay collapse into the last one.
    public func republish(after delay: TimeInterval = 0.25) {
        guard timer != nil else { return }
        republishSerial += 1
        let serial = republishSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.timer != nil, serial == self.republishSerial else { return }
                self.forgetLastAnswer()
                self.poll()
            }
        }
    }

    /// The next ingest reports whatever it finds. `last` is kept: it is what
    /// lets a known indicator survive the pointer resting on it.
    func forgetLastAnswer() { seeded = false }

    /// One read of the window list. Emits only on change — and once at
    /// start, so a subscriber learns the current answer without waiting for
    /// it to flip.
    public func poll() {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
        // NSScreen.screens order IS the arrangement order (DisplayManager.screens()).
        let frames = NSScreen.screens.map(\.frame)
        let mouse = NSEvent.mouseLocation
        ingest(windows: list,
               displays: Self.displayBounds(appKitFrames: frames),
               pointer: CGPoint(x: mouse.x, y: (frames.first?.maxY ?? 0) - mouse.y))
    }

    /// poll() minus the system reads: the seam the tests drive.
    func ingest(windows: [[String: Any]], displays: [CGRect], pointer: CGPoint?) {
        let found = Self.indicators(in: windows, displays: displays, pointer: pointer, known: last)
        if seeded && found == last { return }
        seeded = true
        last = found
        onChange?(found)
    }

    /// AppKit screen frames (y up, primary first) in the window list's space
    /// (y down from the primary's top-left). Entry i is display i + 1.
    nonisolated public static func displayBounds(appKitFrames frames: [CGRect]) -> [CGRect] {
        let primaryMaxY = frames.first?.maxY ?? 0
        return frames.map {
            CGRect(x: $0.minX, y: primaryMaxY - $0.maxY, width: $0.width, height: $0.height)
        }
    }

    /// Every display's indicator among the on-screen windows: one per
    /// display, ascending by display. Matched by what the list gives without
    /// a grant: the WindowServer as owner, a layer far above anything an app
    /// can reach, a small square, and the top strip of the display it is on.
    /// Measured on macOS 27: owner "Window Server", layer 2147483630, 28×28
    /// at y=3 on the built-in display, and at (-6 above, 6 past the right
    /// edge) on a Sidecar. The name ("StatusIndicator") would be the cleanest
    /// key, but names come back empty without Screen Recording — and a bar
    /// that had the grant would not need this file to notice a recording.
    ///
    /// `displays[i]` is display i + 1 in the window list's space. `pointer`
    /// is in that space too; nil skips the cursor test. `known` is the
    /// previous answer.
    nonisolated public static func indicators(
        in windows: [[String: Any]], displays: [CGRect],
        pointer: CGPoint? = nil, known: [RecordingIndicator] = []
    ) -> [RecordingIndicator] {
        // First pass: the small squares, and whether the cursor is already
        // accounted for. While the screen is captured the pointer is a
        // WindowServer window on this very layer, sized by the cursor image.
        // There is one cursor per snapshot: when the overlay holding the
        // pointer is one the shape test rejects anyway (the arrow is 28×40),
        // no small square beside it is the cursor.
        var squares: [CGRect] = []
        var cursorAccountedFor = false
        for window in windows {
            guard let owner = window[kCGWindowOwnerName as String] as? String,
                  owner == "Window Server",
                  let layer = window[kCGWindowLayer as String] as? Int,
                  layer > 1_000_000,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let w = bounds["Width"], let h = bounds["Height"],
                  x.isFinite, y.isFinite, w > 0, h > 0
            else { continue }
            let global = CGRect(x: x, y: y, width: w, height: h)
            if w <= 40, h <= 40, abs(w - h) <= 4 {
                squares.append(global)
            } else if let pointer, w <= cursorLimit, h <= cursorLimit,
                      global.insetBy(dx: -pointerSlack, dy: -pointerSlack).contains(pointer) {
                cursorAccountedFor = true
            }
        }

        var best: [Int: CGRect] = [:]
        for global in squares {
            // Home: the display it overlaps most. A Sidecar's sits at
            // (-22,-6) with the Sidecar left of the main display: it hangs
            // 6pt over its own right edge into the neighbour.
            var home: Int?
            var homeArea: CGFloat = 0
            for (index, display) in displays.enumerated() {
                let overlap = display.intersection(global)
                let area = overlap.isNull ? 0 : overlap.width * overlap.height
                if area > homeArea {
                    home = index
                    homeArea = area
                }
            }
            guard let home else { continue }
            let local = global.offsetBy(dx: -displays[home].minX, dy: -displays[home].minY)
            guard local.minY < topStrip else { continue }
            let candidate = RecordingIndicator(display: home + 1, frame: local)
            // A hand (32×32) or an I-beam (23×22) is a small square like the
            // indicator, and it always contains the pointer. So a square at
            // the pointer is taken for the cursor — unless the cursor was
            // found above, or the square is an indicator already reported:
            // one does not stop being one because the pointer reached it.
            // What is left is a recording that starts while a square cursor
            // rests on the dot: reported once the pointer moves off it.
            if !cursorAccountedFor, let pointer,
               global.insetBy(dx: -pointerSlack, dy: -pointerSlack).contains(pointer),
               !known.contains(candidate) { continue }
            if let held = best[candidate.display], !outranks(local, held) { continue }
            best[candidate.display] = local
        }
        return best.keys.sorted().compactMap { display in
            best[display].map { RecordingIndicator(display: display, frame: $0) }
        }
    }

    /// Rightmost, then topmost, then the larger: a total order, so the
    /// winner never depends on the order the list came back in.
    nonisolated static func outranks(_ a: CGRect, _ b: CGRect) -> Bool {
        (-a.maxX, a.minY, -a.width, -a.height) < (-b.maxX, b.minY, -b.width, -b.height)
    }

    /// The `recording_change` payload. Pure, so the contract is pinned by tests.
    nonisolated public static func environment(for indicators: [RecordingIndicator]) -> [String: String] {
        guard let lead = indicators.first else { return ["RECORDING": "off"] }
        // Not %.0f: that prints "-0".
        func points(_ value: CGFloat) -> String { String(Int(value.rounded())) }
        func csv(_ frame: CGRect) -> String {
            [frame.minX, frame.minY, frame.width, frame.height].map(points).joined(separator: ",")
        }
        return [
            "RECORDING": "on",
            "RECORDING_DISPLAY": String(lead.display),
            "RECORDING_X": points(lead.frame.minX),
            "RECORDING_Y": points(lead.frame.minY),
            "RECORDING_WIDTH": points(lead.frame.width),
            "RECORDING_HEIGHT": points(lead.frame.height),
            "RECORDING_FRAMES": indicators.map { "\($0.display):\(csv($0.frame))" }
                .joined(separator: " "),
        ]
    }
}
