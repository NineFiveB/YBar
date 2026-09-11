import Foundation
import Testing
@testable import YBarKit

/// The width formula every padding and alignment derives from: sketchybar's
/// text_get_length measures tight glyph ink and truncates `(int)(ink + 1.5)`.
/// The port pins the same table in ink_metric_tests.cpp; here it is the
/// reference side, so a change here is a change of contract.
@Suite struct InkMetricTests {
    @Test func widthFormulaTruncatesInkPlusOneAndAHalf() {
        let table: [(ink: CGFloat, width: CGFloat)] = [
            (0.0, 1), (0.4, 1),
            (0.5, 2),     // 0.5 + 1.5 = 2.0
            (9.9, 11),    // 11.4 -> 11
            (10.0, 11),   // 11.5 -> 11 (truncation, not rounding)
            (10.5, 12),
            (41.2, 42),
            (-0.2, 1),    // never negative, whatever the input
        ]
        for entry in table {
            #expect(FontCache.layoutWidth(ink: entry.ink) == entry.width, "ink \(entry.ink)")
        }
    }

    @Test func degenerateInkNeverTrapsOrGoesNegative() {
        #expect(FontCache.layoutWidth(ink: -3) == 0)
        #expect(FontCache.layoutWidth(ink: .nan) == 0)
        #expect(FontCache.layoutWidth(ink: .infinity) == 0)
    }

    @MainActor
    @Test func shapedLineWidthIsTheFormulaOverItsOwnInk() {
        let cache = FontCache()
        var spec = FontSpec()
        spec.size = 14
        for text in ["12:00", "W", "i", "Battery 75%"] {
            let shaped = cache.shapedLine(text: text, spec: spec)
            #expect(shaped.width == FontCache.layoutWidth(ink: shaped.inkWidth), "\(text)")
            #expect(shaped.width >= shaped.inkWidth, "\(text)")
        }
    }
}
