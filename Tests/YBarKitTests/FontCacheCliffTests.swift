import AppKit
import Testing
@testable import YBarKit

/// The two FontCache cliffs that turn one item into a dropped tick: a symbol
/// name AppKit cannot resolve, and a font size that is animated.
@MainActor
@Suite struct FontCacheCliffTests {
    @Test func anUnresolvableSymbolIsAskedForOnce() {
        let cache = FontCache()
        #expect(cache.symbolImage(name: "definitely.not.a.symbol.ybar", pointSize: 12) == nil)
        #expect(cache.symbolResolutions == 1)
        // The nil used to be returned BEFORE the cache write, so every
        // measurement of every frame re-entered AppKit — forever, for one typo.
        for _ in 0..<50 {
            #expect(cache.symbolImage(name: "definitely.not.a.symbol.ybar", pointSize: 12) == nil)
        }
        #expect(cache.symbolResolutions == 1)
    }

    @Test func aResolvableSymbolIsAskedForOncePerQuarterPoint() {
        let cache = FontCache()
        _ = cache.symbolImage(name: "wifi", pointSize: 12)
        _ = cache.symbolImage(name: "wifi", pointSize: 12)
        #expect(cache.symbolResolutions == 1)
        _ = cache.symbolImage(name: "wifi", pointSize: 12.25)
        #expect(cache.symbolResolutions == 2)
    }

    /// An `--animate` on `font` used to mint a shaped line, a CTFont and a
    /// configured NSImage per interpolated frame while the glyph atlas — which
    /// already bucketed its own keys — hit its cache. One grid now, set at the
    /// source, so every cache keyed on a font agrees what a distinct size is.
    @Test func aFontSizeIsQuantizedToTheQuarterPointOnTheWayIn() {
        var spec = FontSpec()
        spec.size = 12.1
        #expect(spec.size == 12)
        var other = FontSpec()
        other.size = 12.0
        #expect(spec == other)
        spec.size = 12.2
        #expect(spec.size == 12.25)
        #expect(FontSpec.quantize(12.874) == 12.75)
        #expect(FontSpec.quantize(12.9) == 13)
    }

    @Test func anAnimatedFontSizeVisitsBoundedlyManyShapedLines() {
        let cache = FontCache()
        var seen = Set<FontSpec>()
        // 12 -> 20 pt over 240 frames: 33 quarter-point buckets, not 240.
        for frame in 0...240 {
            var spec = FontSpec()
            spec.size = 12 + 8 * Float(frame) / 240
            seen.insert(spec)
            _ = cache.shapedLine(text: "CPU 12%", spec: spec)
        }
        #expect(seen.count == 33)
    }

    /// The parsed form takes the same grid: "Helvetica::12.1" and
    /// "Helvetica::12" are one font, one shaped line and one atlas entry.
    @Test func aParsedSpecIsQuantizedToo() {
        var parsed = FontSpec()
        parsed.apply("Helvetica::12.1")
        #expect(parsed.size == 12)
    }
}
