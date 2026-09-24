import Foundation
import Testing
@testable import YBarKit

/// Where a quad lands on the device pixel grid. Every quad in every scene —
/// pill, bracket, text plate, popup panel, shadow, slider track, gauge, graph
/// bar and tick — is built from `pixelOrigin` and `pixelSize` on the same
/// rect, so what they agree on is what the bar looks like.
@MainActor
@Suite struct PixelGridTests {
    /// Rounding the origin and the EXTENT independently lets them disagree:
    /// `round(x·s) + round(w·s)` is not `round((x+w)·s)`. On a 61.37 pt pill
    /// slid 30 pt in 0.1 pt steps at 2x they disagreed on 60 of 301 steps, so
    /// a pill of constant width breathed by a pixel as it slid, and its right
    /// edge drifted off whatever was anchored to it.
    @Test func aQuadsFarEdgeLandsWhereTheNextQuadsNearEdgeDoes() {
        for step in 0...300 {
            let x = 10 + Double(step) * 0.1
            let rect = CGRect(x: x, y: 4.3, width: 61.37, height: 20.7)
            let origin = SceneBuilder.pixelOrigin(rect, scale: 2)
            let size = SceneBuilder.pixelSize(rect, scale: 2)
            let abutting = SceneBuilder.pixelOrigin(
                CGRect(x: rect.maxX, y: rect.maxY, width: 10, height: 10), scale: 2)
            #expect(origin.x + size.x == abutting.x)
            #expect(origin.y + size.y == abutting.y)
        }
    }

    /// Whole-pixel geometry is unaffected: the common case still rounds to
    /// exactly what it did.
    @Test func geometryAlreadyOnTheGridIsUnchanged() {
        let rect = CGRect(x: 12, y: 4, width: 60, height: 22)
        #expect(SceneBuilder.pixelOrigin(rect, scale: 2) == SIMD2<Float>(24, 8))
        #expect(SceneBuilder.pixelSize(rect, scale: 2) == SIMD2<Float>(120, 44))
        #expect(SceneBuilder.pixelSize(rect, scale: 1) == SIMD2<Float>(60, 22))
    }
}
