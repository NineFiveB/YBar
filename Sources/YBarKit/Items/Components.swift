import CoreGraphics
import Foundation

/// What an item fundamentally is. sketchybar's one-char type tags, typed.
public enum ItemKind: String, Sendable {
    case item
    case graph
    case slider
    case bracket
}

/// Ring buffer of normalized samples (0...1), fed by `--push <name> <values…>`.
/// Width in samples == width in points (sketchybar's sample_width = 1).
@MainActor
public final class GraphState {
    public let capacity: Int
    public private(set) var values: [Float]
    private var cursor: Int = 0

    public var lineColor: YColor = .white
    /// nil = derive from lineColor at 20% alpha (sketchybar default).
    public var fillColor: YColor?
    public var lineWidth: Float = 1.0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        values = [Float](repeating: 0, count: self.capacity)
    }

    public func push(_ value: Float) {
        values[cursor] = min(1, max(0, value))
        cursor = (cursor + 1) % capacity
    }

    /// Samples in display order: oldest first, newest last.
    public func ordered() -> [Float] {
        Array(values[cursor...] + values[..<cursor])
    }

    public var effectiveFillColor: YColor {
        if let fillColor { return fillColor }
        var derived = lineColor
        derived.alpha *= 0.2
        return derived
    }
}

/// Draggable slider: track background + highlight fill + optional glyph knob.
@MainActor
public final class SliderState {
    /// 0...100 (sketchybar convention).
    public var percentage: Float = 0
    public var width: Float
    public var highlightColor: YColor = .white
    /// Any string renders as the knob (glyph/emoji/sf:symbol); empty = no knob.
    public var knob = TextPart()
    public var background = BackgroundStyle()
    public var isDragged = false

    public init(width: Float) {
        self.width = max(1, width)
        background.drawing = true
        background.color = YColor(argb: 0x4DFF_FFFF)
        background.height = 6
        background.cornerRadius = 3
    }

    public func percentage(forLocalX x: CGFloat) -> Float {
        min(100, max(0, Float(x / CGFloat(width)) * 100))
    }
}

/// Anchored popup panel owned by a host item; members are items added at
/// position `popup.<host>`.
public struct PopupState: Sendable {
    public var isOpen = false
    public var horizontal = false
    /// Fixed row height; 0 = each row sizes to its content.
    public var cellHeight: Float = 0
    public var yOffset: Float = 0
    /// Close when the user clicks anywhere outside YBar (YBar extension;
    /// `popup.auto_close=off` restores sketchybar's script-only lifecycle).
    public var autoClose = true
    /// Horizontal anchoring against the host item: l/c/r.
    public var align: Character = "l"
    /// > 0: blurred system material behind the whole panel.
    public var blurRadius: Float = 0
    public var background = BackgroundStyle()

    public init() {
        background.drawing = true
        background.color = YColor(argb: 0xEE22_2222)
        background.cornerRadius = 8
    }
}

/// Pure geometry for M4 components, split out for testability.
public enum ComponentGeometry {
    /// Interactive frames for bracket items (full bar height, like in-flow item
    /// frames) — must be computed after layout and BEFORE the per-surface hit
    /// snapshot, or brackets can never be clicked/hovered/host popups.
    @MainActor
    public static func bracketFrames(
        items: [Item], contentBoxes: [Int: CGRect], barHeight: CGFloat
    ) -> [Int: CGRect] {
        var frames: [Int: CGRect] = [:]
        for item in items where item.kind == .bracket && item.drawing {
            let memberBoxes = expandMembers(item.members, in: items).compactMap {
                contentBoxes[$0.id]
            }
            if let union = bracketUnion(
                memberBoxes: memberBoxes,
                paddingLeft: CGFloat(item.paddingLeft),
                paddingRight: CGFloat(item.paddingRight)) {
                frames[item.id] = CGRect(x: union.minX, y: 0, width: union.width, height: barHeight)
            } else {
                frames[item.id] = .zero
            }
        }
        return frames
    }

    /// Expand bracket member entries (names or sketchybar `/regex/` patterns).
    @MainActor
    public static func expandMembers(_ members: [String], in items: [Item]) -> [Item] {
        var seen = Set<Int>()
        var result: [Item] = []
        for entry in members {
            if let pattern = ItemStore.regexPattern(from: entry) {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for item in items where !seen.contains(item.id) {
                    let range = NSRange(item.name.startIndex..., in: item.name)
                    if regex.firstMatch(in: item.name, options: [], range: range) != nil {
                        seen.insert(item.id)
                        result.append(item)
                    }
                }
            } else if let item = items.first(where: { $0.name == entry }), !seen.contains(item.id) {
                seen.insert(item.id)
                result.append(item)
            }
        }
        return result
    }

    /// Bracket background box: the union of member content boxes, expanded by
    /// the bracket's own paddings. Nil when no member is visible.
    public static func bracketUnion(
        memberBoxes: [CGRect], paddingLeft: CGFloat, paddingRight: CGFloat
    ) -> CGRect? {
        let visible = memberBoxes.filter { $0 != .zero && $0.width > 0 }
        guard let first = visible.first else { return nil }
        var union = first
        for box in visible.dropFirst() { union = union.union(box) }
        return CGRect(
            x: union.minX - paddingLeft,
            y: union.minY,
            width: union.width + paddingLeft + paddingRight,
            height: union.height)
    }

    /// Vertical popup layout: rows of (item natural size + paddings), stacked.
    /// Returns per-item content boxes (popup-local, top-left origin) and the
    /// popup content size.
    public static func popupLayout(
        rows: [(itemID: Int, size: CGSize, paddingLeft: CGFloat, paddingRight: CGFloat)],
        cellHeight: CGFloat,
        horizontal: Bool,
        inset: CGFloat
    ) -> (boxes: [Int: CGRect], contentSize: CGSize) {
        var boxes: [Int: CGRect] = [:]
        if horizontal {
            var x = inset
            var maxHeight: CGFloat = 0
            for row in rows {
                let height = cellHeight > 0 ? cellHeight : row.size.height
                x += row.paddingLeft
                boxes[row.itemID] = CGRect(x: x, y: inset, width: row.size.width, height: height)
                x += row.size.width + row.paddingRight
                maxHeight = max(maxHeight, height)
            }
            for (id, box) in boxes {
                boxes[id] = CGRect(x: box.minX, y: inset, width: box.width, height: maxHeight)
            }
            return (boxes, CGSize(width: x + inset, height: maxHeight + 2 * inset))
        }

        var y = inset
        var maxWidth: CGFloat = 0
        for row in rows {
            let height = cellHeight > 0 ? cellHeight : row.size.height
            let width = row.paddingLeft + row.size.width + row.paddingRight
            boxes[row.itemID] = CGRect(x: inset + row.paddingLeft, y: y, width: row.size.width, height: height)
            y += height
            maxWidth = max(maxWidth, width)
        }
        return (boxes, CGSize(width: maxWidth + 2 * inset, height: y + inset))
    }

    /// Tessellate a graph into triangles: filled area under the polyline plus a
    /// constant-thickness line built from per-segment quads. `box` is the graph
    /// area (top-left origin, y-down); samples are 0...1 (1 = top).
    public static func tessellateGraph(
        samples: [Float], box: CGRect, lineWidth: CGFloat, rightToLeft: Bool
    ) -> (fill: [SIMD2<Float>], line: [SIMD2<Float>]) {
        guard samples.count >= 2, box.width > 0, box.height > 0 else { return ([], []) }
        let count = samples.count
        let stepX = box.width / CGFloat(count - 1)

        func point(_ index: Int) -> SIMD2<Float> {
            let ordered = rightToLeft ? count - 1 - index : index
            let x = box.minX + CGFloat(index) * stepX
            let y = box.maxY - CGFloat(samples[ordered]) * box.height
            return SIMD2(Float(x), Float(y))
        }

        var fill: [SIMD2<Float>] = []
        fill.reserveCapacity((count - 1) * 6)
        let baseY = Float(box.maxY)
        for index in 0..<(count - 1) {
            let a = point(index)
            let b = point(index + 1)
            let aBase = SIMD2(a.x, baseY)
            let bBase = SIMD2(b.x, baseY)
            fill.append(contentsOf: [a, b, aBase, b, bBase, aBase])
        }

        var line: [SIMD2<Float>] = []
        line.reserveCapacity((count - 1) * 6)
        let half = Float(lineWidth) / 2
        for index in 0..<(count - 1) {
            let a = point(index)
            let b = point(index + 1)
            let direction = b - a
            let length = max(0.0001, (direction.x * direction.x + direction.y * direction.y).squareRoot())
            let normal = SIMD2(-direction.y / length, direction.x / length) * half
            line.append(contentsOf: [a - normal, a + normal, b - normal,
                                     a + normal, b + normal, b - normal])
        }
        return (fill, line)
    }
}
