import CoreGraphics

/// Measured content of one item, produced by the text measurer.
public struct MeasuredContent {
    public var iconSize: CGSize
    public var labelSize: CGSize

    public init(iconSize: CGSize = .zero, labelSize: CGSize = .zero) {
        self.iconSize = iconSize
        self.labelSize = labelSize
    }
}

/// Pure layout of items along a horizontal bar — sketchybar's proven five-cursor
/// algorithm: left→, ←right, a centered center block (pre-pass sum), and
/// notch-anchored centerLeft/centerRight cursors flowing away from the dead zone.
///
/// All geometry is in bar-local points with a top-left origin. Layout writes
/// `item.frame` (the full interactive extent, bar height tall) and returns the
/// content boxes used by the renderer.
@MainActor
public enum Layout {
    public struct Result {
        /// Content box per item id: the area covered by background/text (without outer paddings).
        public var contentBoxes: [Int: CGRect] = [:]
    }

    /// Length of the item content: icon + label with their paddings (or fixed width).
    public static func contentLength(item: Item, measured: MeasuredContent) -> CGFloat {
        if item.customWidth >= 0 { return CGFloat(item.customWidth) }
        return naturalLength(item: item, measured: measured)
    }

    /// Content length ignoring any fixed-width override — the value `width=dynamic`
    /// animations resolve the -1 sentinel to.
    public static func naturalLength(item: Item, measured: MeasuredContent) -> CGFloat {
        // sketchybar parity: a drawing part contributes its paddings even with
        // an empty string (text_get_length gates on drawing alone).
        var length: CGFloat = 0
        if item.icon.drawing {
            length += CGFloat(item.icon.paddingLeft) + measured.iconSize.width + CGFloat(item.icon.paddingRight)
        }
        length += item.contentWidth
        if item.label.drawing {
            length += CGFloat(item.label.paddingLeft) + measured.labelSize.width + CGFloat(item.label.paddingRight)
        }
        return length
    }

    @discardableResult
    public static func perform(
        items: [Item],
        barSize: CGSize,
        settings: BarSettings,
        measure: (Item) -> MeasuredContent
    ) -> Result {
        var result = Result()
        let width = barSize.width
        let notchHalf = CGFloat(settings.notchWidth) / 2

        func place(_ item: Item, x: CGFloat, measured: MeasuredContent) {
            let length = contentLength(item: item, measured: measured)
            let box = CGRect(x: x, y: 0, width: length, height: barSize.height)
            item.frame = CGRect(
                x: x - CGFloat(item.paddingLeft),
                y: 0,
                width: length + CGFloat(item.paddingLeft) + CGFloat(item.paddingRight),
                height: barSize.height
            )
            result.contentBoxes[item.id] = box
        }

        // Left: flows right from the bar's left padding.
        var cursor = CGFloat(settings.paddingLeft)
        for item in items where item.position == .left && item.isVisible && item.isInBarFlow {
            let measured = measure(item)
            cursor += CGFloat(item.paddingLeft)
            place(item, x: cursor, measured: measured)
            cursor += contentLength(item: item, measured: measured) + CGFloat(item.paddingRight)
        }

        // Right: flows left from the bar's right padding.
        cursor = width - CGFloat(settings.paddingRight)
        for item in items where item.position == .right && item.isVisible && item.isInBarFlow {
            let measured = measure(item)
            cursor -= CGFloat(item.paddingRight)
            let length = contentLength(item: item, measured: measured)
            cursor -= length
            place(item, x: cursor, measured: measured)
            cursor -= CGFloat(item.paddingLeft)
        }

        // Center: pre-pass sums the block, then flows right from the centered origin.
        let centerItems = items.filter { $0.position == .center && $0.isVisible && $0.isInBarFlow }
        if !centerItems.isEmpty {
            var measures: [Int: MeasuredContent] = [:]
            var total: CGFloat = 0
            for item in centerItems {
                let measured = measure(item)
                measures[item.id] = measured
                total += CGFloat(item.paddingLeft) + contentLength(item: item, measured: measured)
                    + CGFloat(item.paddingRight)
            }
            cursor = (width - total) / 2
            for item in centerItems {
                let measured = measures[item.id]!
                cursor += CGFloat(item.paddingLeft)
                place(item, x: cursor, measured: measured)
                cursor += contentLength(item: item, measured: measured) + CGFloat(item.paddingRight)
            }
        }

        // centerLeft (q): flows left, starting at the notch's left edge.
        cursor = width / 2 - notchHalf
        for item in items where item.position == .centerLeft && item.isVisible && item.isInBarFlow {
            let measured = measure(item)
            cursor -= CGFloat(item.paddingRight)
            let length = contentLength(item: item, measured: measured)
            cursor -= length
            place(item, x: cursor, measured: measured)
            cursor -= CGFloat(item.paddingLeft)
        }

        // centerRight (e): flows right, starting at the notch's right edge.
        cursor = width / 2 + notchHalf
        for item in items where item.position == .centerRight && item.isVisible && item.isInBarFlow {
            let measured = measure(item)
            cursor += CGFloat(item.paddingLeft)
            place(item, x: cursor, measured: measured)
            cursor += contentLength(item: item, measured: measured) + CGFloat(item.paddingRight)
        }

        // Invisible items get an empty frame so hit testing skips them.
        for item in items where !item.isVisible || !item.isInBarFlow {
            item.frame = .zero
            result.contentBoxes[item.id] = .zero
        }

        return result
    }
}
