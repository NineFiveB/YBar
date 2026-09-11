import Foundation
import Testing
@testable import YBarKit

/// Scheduler behaviour beyond landing and retargeting (AnimationTests):
/// curve application, colour interpolation, what a retarget does to the
/// superseded completion, and the frame callback contract the marquee and
/// the renderer's re-encode depend on. All driven through `tick(now:)`.
@MainActor
@Suite struct AnimationSchedulerContractTests {
    private func floatSink(_ store: @escaping (Float) -> Void) -> (AnimValue) -> Void {
        { if case .float(let current) = $0 { store(current) } }
    }

    @Test func curveShapesTheMidpoint() {
        let scheduler = AnimationScheduler()
        var value: Float = 0
        scheduler.animate(key: "k", from: .float(0), to: .float(100), durationFrames: 30,
                          curve: .quadratic, apply: floatSink { value = $0 })
        scheduler.tick(now: 0)
        scheduler.tick(now: 0.25)  // t = 0.5 -> quadratic 0.25
        #expect(abs(value - 25) < 0.01)
    }

    @Test func colorsLerpInLinearLightThroughTheScheduler() {
        let scheduler = AnimationScheduler()
        var value = YColor(argb: 0)
        scheduler.animate(key: "k", from: .color(YColor(argb: 0xFFFF_0000)), to: .color(YColor(argb: 0xFF00_FF00)),
                          durationFrames: 30, curve: .linear,
                          apply: { if case .color(let current) = $0 { value = current } })
        scheduler.tick(now: 0)
        scheduler.tick(now: 0.25)  // midpoint
        // A linear-light midpoint is visibly brighter than the naive per-byte 0x80.
        #expect((value.argb >> 16) & 0xFF > 0xB0)
        #expect((value.argb >> 8) & 0xFF > 0xB0)
        #expect(value.argb >> 24 == 0xFF)
    }

    @Test func retargetDropsTheSupersededCompletion() {
        let scheduler = AnimationScheduler()
        var firstCompleted = false
        var secondCompleted = false
        scheduler.animate(key: "k", from: .float(0), to: .float(1), durationFrames: 60,
                          curve: .linear, apply: { _ in }, onComplete: { firstCompleted = true })
        scheduler.tick(now: 0)
        scheduler.animate(key: "k", from: .float(0.5), to: .float(0), durationFrames: 6,
                          curve: .linear, apply: { _ in }, onComplete: { secondCompleted = true })
        scheduler.tick(now: 1)
        scheduler.tick(now: 2)
        #expect(!firstCompleted)
        #expect(secondCompleted)
        #expect(!scheduler.isAnimating)
    }

    @Test func onFrameFiresOnEveryTickIncludingTheLandingOne() {
        let scheduler = AnimationScheduler()
        var frames = 0
        scheduler.onFrame = { frames += 1 }
        scheduler.animate(key: "k", from: .float(0), to: .float(1), durationFrames: 6,
                          curve: .linear, apply: { _ in })
        scheduler.tick(now: 0)
        scheduler.tick(now: 0.05)
        scheduler.tick(now: 1)   // lands
        #expect(frames == 3)
        #expect(!scheduler.isAnimating)
    }

    @Test func continuousDemandIsNotAnAnimationButStillTicksFrames() {
        // Marquee text keeps the clock alive with zero property animations;
        // every frame must still reach onFrame so the scene re-encodes.
        let scheduler = AnimationScheduler()
        var frames = 0
        scheduler.onFrame = { frames += 1 }
        scheduler.continuousDemand = true
        #expect(!scheduler.isAnimating)
        scheduler.tick(now: 1)
        #expect(frames == 1)
        scheduler.continuousDemand = false
        #expect(!scheduler.isAnimating)
    }

    @Test func independentKeysFinishOnTheirOwnClocks() {
        let scheduler = AnimationScheduler()
        var shortDone = false
        var longValue: Float = 0
        scheduler.animate(key: "short", from: .float(0), to: .float(1), durationFrames: 6,
                          curve: .linear, apply: { _ in }, onComplete: { shortDone = true })
        scheduler.animate(key: "long", from: .float(0), to: .float(60), durationFrames: 60,
                          curve: .linear, apply: floatSink { longValue = $0 })
        scheduler.tick(now: 0)
        scheduler.tick(now: 0.2)
        #expect(shortDone)
        #expect(scheduler.isAnimating)
        #expect(abs(longValue - 12) < 0.01)  // 0.2 s of a 1 s sweep to 60
        scheduler.tick(now: 1.5)
        #expect(longValue == 60)
        #expect(!scheduler.isAnimating)
    }

    @Test func cancelAllDropsEverythingWithoutCompleting() {
        let scheduler = AnimationScheduler()
        var completed = 0
        for key in ["a", "b"] {
            scheduler.animate(key: key, from: .float(0), to: .float(1), durationFrames: 6,
                              curve: .linear, apply: { _ in }, onComplete: { completed += 1 })
        }
        scheduler.cancelAll()
        #expect(!scheduler.isAnimating)
        scheduler.tick(now: 10)
        #expect(completed == 0)
    }
}
