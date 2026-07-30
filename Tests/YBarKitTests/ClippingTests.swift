import Foundation
import simd
import Testing
@testable import YBarKit

/// Fixed-width clipping: glyph quads intersect the item content box with
/// proportional UV remap (review finding: width animations overprinted neighbors).
@MainActor
@Suite struct GlyphClippingTests {
    private func entry(size: SIMD2<Float>) -> GlyphAtlas.Entry {
        GlyphAtlas.Entry(
            uvOrigin: SIMD2(0.5, 0.5),
            uvSize: SIMD2(0.1, 0.1),
            sizePx: size,
            bearingPx: SIMD2(0, 0),
            isColor: false)
    }

    @Test func noClipPassesThrough() {
        let instance = SceneBuilder.glyphInstance(
            origin: SIMD2(10, 10), entry: entry(size: SIMD2(20, 20)),
            color: SIMD4(repeating: 1), clip: nil)
        #expect(instance != nil)
        #expect(instance?.origin == SIMD2(10, 10))
        #expect(instance?.uvSize == SIMD2(0.1, 0.1))
    }

    @Test func fullyOutsideIsDropped() {
        let clip = CGRect(x: 0, y: 0, width: 100, height: 40)
        let instance = SceneBuilder.glyphInstance(
            origin: SIMD2(200, 10), entry: entry(size: SIMD2(20, 20)),
            color: SIMD4(repeating: 1), clip: clip)
        #expect(instance == nil)
    }

    @Test func partialClipRemapsUVsProportionally() {
        // Glyph spans x 90..110; clip ends at 100 → right half cut.
        let clip = CGRect(x: 0, y: 0, width: 100, height: 40)
        let instance = SceneBuilder.glyphInstance(
            origin: SIMD2(90, 10), entry: entry(size: SIMD2(20, 20)),
            color: SIMD4(repeating: 1), clip: clip)
        #expect(instance != nil)
        guard let instance else { return }
        #expect(instance.origin == SIMD2(90, 10))
        #expect(instance.size == SIMD2(10, 20))
        // UV keeps the left half: origin unchanged, width halved.
        #expect(abs(instance.uvOrigin.x - 0.5) < 1e-6)
        #expect(abs(instance.uvSize.x - 0.05) < 1e-6)
        // Vertical extent untouched.
        #expect(abs(instance.uvSize.y - 0.1) < 1e-6)
    }

    @Test func leftEdgeClipShiftsUVOrigin() {
        // Glyph spans x -10..10; clip starts at 0 → left half cut.
        let clip = CGRect(x: 0, y: 0, width: 100, height: 40)
        let instance = SceneBuilder.glyphInstance(
            origin: SIMD2(-10, 10), entry: entry(size: SIMD2(20, 20)),
            color: SIMD4(repeating: 1), clip: clip)
        #expect(instance != nil)
        guard let instance else { return }
        #expect(instance.origin == SIMD2(0, 10))
        #expect(instance.size == SIMD2(10, 20))
        #expect(abs(instance.uvOrigin.x - 0.55) < 1e-6)
        #expect(abs(instance.uvSize.x - 0.05) < 1e-6)
    }
}

@Suite struct LinearColorTests {
    @Test func simdIsLinearized() {
        // 0xFF808080: sRGB 0.502 → linear ≈ 0.2158; alpha stays straight.
        let gray = YColor(argb: 0xFF80_8080)
        let v = gray.simd
        #expect(abs(v.x - 0.2158) < 0.005)
        #expect(v.w == 1.0)
        // Round trip through the transfer functions is identity.
        #expect(abs(YColor.toGamma(YColor.toLinear(0.502)) - 0.502) < 1e-5)
    }
}
