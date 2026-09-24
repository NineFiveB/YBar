import AppKit
import Foundation
import simd
import Testing
@testable import YBarKit

/// Opt-in measurement harness (`YBAR_BENCH=1 swift test --filter PerfBench`).
/// It never runs in CI: the numbers are wall-clock and machine-specific, and a
/// timing assertion on a shared runner is a flake generator. Two lenses:
///
///  - `tickCostMicroseconds` — the CPU a full paint's worth of layout + scene
///    building costs, against the 8.33 ms budget of a 120 Hz frame.
///  - the quantization lenses — how many DISTINCT pictures a motion produces
///    over its ticks. A frame byte-identical to the one before it is a frame
///    the panel was refreshed for and nothing moved, so doubling the refresh
///    rate buys nothing. This is the number the sub-pixel work has to move.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YBAR_BENCH"] != nil))
struct PerfBench {
    static let scale: CGFloat = 2
    static let barSize = CGSize(width: 1600, height: 32)

    /// A realistic bar: 25 items, a mix of plain labels, sf: icons and
    /// backgrounds, wrapped in two brackets.
    static func barItems() -> [Item] {
        var items: [Item] = []
        let labels = ["CPU 12%", "RAM 48%", "wlan0", "92%", "14:31", "Mail", "Slack",
                      "Spotify", "1", "2", "3", "4", "5", "Finder", "Terminal"]
        for index in 0..<25 {
            let item = Item(name: "i\(index)", position: index < 12 ? .left : .right)
            if index % 3 == 0 {
                item.icon.string = "sf:circle.fill"
                item.icon.font.size = 12
            }
            item.label.string = labels[index % labels.count]
            item.label.font.size = 12
            item.background.drawing = true
            item.background.cornerRadius = 6
            item.background.color = YColor(argb: 0x8022_2233)
            item.background.paddingLeft = 6
            item.background.paddingRight = 6
            items.append(item)
        }
        for (offset, range) in [(0, 0..<6), (1, 12..<18)] {
            let bracket = Item(name: "b\(offset)", position: .left)
            bracket.kind = .bracket
            bracket.members = range.map { "i\($0)" }
            bracket.background.drawing = true
            bracket.background.cornerRadius = 8
            bracket.background.color = YColor(argb: 0x4011_1122)
            items.append(bracket)
        }
        return items
    }

    /// A 12-row popup hosted by the first item.
    static func popupMembers() -> [Item] {
        (0..<12).map { index in
            let item = Item(name: "p\(index)", position: .popup)
            item.label.string = "row \(index) — some menu text"
            item.label.font.size = 12
            item.background.drawing = true
            item.background.cornerRadius = 4
            return item
        }
    }

    static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }

    @Test func tickCostMicroseconds() {
        let fontCache = FontCache()
        let builder = SceneBuilder(fontCache: fontCache)
        let atlas = GlyphAtlas(scale: Self.scale)
        let settings = BarSettings()
        let items = Self.barItems()
        let host = items[0]
        let members = Self.popupMembers()
        let measure = { (item: Item) in
            MeasuredContent(iconSize: fontCache.measure(part: item.icon),
                            labelSize: fontCache.measure(part: item.label))
        }

        var barOnly: [Double] = []
        var full: [Double] = []
        for iteration in 0..<600 {
            let start = CFAbsoluteTimeGetCurrent()
            let result = Layout.perform(items: items, barSize: Self.barSize,
                                        settings: settings, notchWidth: 0, measure: measure)
            let bracketFrames = ComponentGeometry.bracketFrames(
                items: items, contentBoxes: result.contentBoxes, barHeight: Self.barSize.height)
            for (itemID, frame) in bracketFrames { items.first { $0.id == itemID }?.frame = frame }
            _ = items.map { ($0.id, $0.frame) }
            builder.clock = Double(iteration) / 120
            let list = builder.build(items: items, settings: settings,
                                     contentBoxes: result.contentBoxes, barSize: Self.barSize,
                                     scale: Self.scale, atlas: atlas)
            let afterBar = CFAbsoluteTimeGetCurrent()
            let popup = builder.buildPopup(host: host, members: members,
                                           scale: Self.scale, atlas: atlas)
            let end = CFAbsoluteTimeGetCurrent()
            _ = list.quads.count + popup.list.quads.count
            // The first ~100 iterations populate the shaped-line, symbol and
            // atlas caches; a real bar has been up for hours.
            if iteration >= 100 {
                barOnly.append((afterBar - start) * 1e6)
                full.append((end - start) * 1e6)
            }
        }
        barOnly.sort()
        full.sort()
        print(String(format: "[bench] bar-only tick: mean %.1f us  p50 %.1f  p95 %.1f",
                     barOnly.reduce(0, +) / Double(barOnly.count),
                     Self.percentile(barOnly, 0.5), Self.percentile(barOnly, 0.95)))
        print(String(format: "[bench] bar+popup tick: mean %.1f us  p50 %.1f  p95 %.1f  (8333 us budget @120Hz)",
                     full.reduce(0, +) / Double(full.count),
                     Self.percentile(full, 0.5), Self.percentile(full, 0.95)))
    }

    /// The signature of every quad and glyph an item emits, as the GPU would
    /// see it. Two frames with the same signature are the same picture.
    static func signature(_ list: DisplayList) -> String {
        var parts: [String] = []
        for quad in list.quads {
            parts.append("q\(quad.origin.x),\(quad.origin.y),\(quad.size.x),\(quad.size.y)")
        }
        for glyph in list.glyphs {
            parts.append("g\(glyph.origin.x),\(glyph.origin.y)")
        }
        return parts.joined(separator: "|")
    }

    private func sweep(hz: Double, durationFrames: Int, curve: AnimationCurve,
                       apply: (Item, Double) -> Void) -> (distinct: Int, ticks: Int) {
        let fontCache = FontCache()
        let builder = SceneBuilder(fontCache: fontCache)
        let atlas = GlyphAtlas(scale: Self.scale)
        let settings = BarSettings()
        let item = Item(name: "hover", position: .left)
        item.label.string = "hover me"
        item.background.drawing = true
        item.background.cornerRadius = 6
        item.background.color = YColor(argb: 0xFF22_2233)
        let measure = { (probe: Item) in
            MeasuredContent(iconSize: fontCache.measure(part: probe.icon),
                            labelSize: fontCache.measure(part: probe.label))
        }
        let duration = Double(durationFrames) / 60
        var signatures: [String] = []
        var now = 0.0
        while now <= duration + 1e-9 {
            apply(item, curve.value(min(1, now / duration)))
            let result = Layout.perform(items: [item], barSize: Self.barSize,
                                        settings: settings, notchWidth: 0, measure: measure)
            let list = builder.build(items: [item], settings: settings,
                                     contentBoxes: result.contentBoxes, barSize: Self.barSize,
                                     scale: Self.scale, atlas: atlas)
            signatures.append(Self.signature(list))
            now += 1 / hz
        }
        var distinct = 1
        for index in 1..<signatures.count where signatures[index] != signatures[index - 1] {
            distinct += 1
        }
        return (distinct, signatures.count)
    }

    @Test func hoverLiftMotionSamples() {
        for hz in [60.0, 120.0] {
            let lift = sweep(hz: hz, durationFrames: 8, curve: .tanh) { item, t in
                item.yOffset = Float(t * 3)
            }
            print(String(format: "[bench] hover y_offset 0->3pt, tanh/8 @%.0fHz: %d changed frames of %d ticks",
                         hz, lift.distinct, lift.ticks))
            let grow = sweep(hz: hz, durationFrames: 8, curve: .tanh) { item, t in
                item.background.height = Float(20 + t * 3)
            }
            print(String(format: "[bench] hover background.height 20->23pt, tanh/8 @%.0fHz: %d changed frames of %d ticks",
                         hz, grow.distinct, grow.ticks))
        }
    }

    @Test func marqueeMotionSamples() {
        for (hz, duration) in [(60.0, 100), (120.0, 100), (60.0, 70), (120.0, 70)] {
            let fontCache = FontCache()
            let builder = SceneBuilder(fontCache: fontCache)
            let atlas = GlyphAtlas(scale: Self.scale)
            let settings = BarSettings()
            let item = Item(name: "m", position: .left)
            item.label.string = "a long scrolling now playing title that overflows its slot"
            item.label.customWidth = 200
            item.label.scrollDuration = duration
            item.scrollTexts = true
            let measure = { (probe: Item) in
                MeasuredContent(iconSize: fontCache.measure(part: probe.icon),
                                labelSize: fontCache.measure(part: probe.label))
            }
            // Glyphs scroll out of the slot clip, so no single glyph can be
            // followed across the run. Every surviving glyph translates by the
            // same amount though, so the modal pairwise difference between two
            // frames' glyph x positions IS that frame's scroll step.
            var frames: [[Float]] = []
            for frame in 0..<Int(hz) {
                builder.clock = Double(frame) / hz
                let result = Layout.perform(items: [item], barSize: Self.barSize,
                                            settings: settings, notchWidth: 0, measure: measure)
                let list = builder.build(items: [item], settings: settings,
                                         contentBoxes: result.contentBoxes, barSize: Self.barSize,
                                         scale: Self.scale, atlas: atlas)
                frames.append(list.glyphs.map(\.origin.x))
            }
            var steps: [Float] = []
            for index in 1..<frames.count {
                var histogram: [Float: Int] = [:]
                for after in frames[index] {
                    for before in frames[index - 1] {
                        let delta = before - after
                        guard delta >= -0.5, delta <= 25 else { continue }
                        histogram[(delta * 1000).rounded() / 1000, default: 0] += 1
                    }
                }
                if let best = histogram.max(by: { $0.value < $1.value })?.key { steps.append(best) }
            }
            let minimum = steps.min() ?? 0
            let maximum = steps.max() ?? 0
            let mean = steps.reduce(0, +) / Float(max(1, steps.count))
            let swing = mean > 0 ? (maximum - minimum) / mean * 100 : 0
            print(String(format: "[bench] marquee scroll_duration=%d @%.0fHz: %.3f px/frame mean, step %.3f..%.3f, velocity swing %.0f%%",
                         duration, hz, mean, minimum, maximum, swing))
        }
    }
}
