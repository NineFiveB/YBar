import Foundation
import Testing
@testable import YBarKit

/// Scheduler contract, driven through the `tick(now:)` seam (no display
/// link): frames-at-60Hz durations, exact final values, retarget-not-queue,
/// cancel-without-complete, and the review finding A9 -- a completion that
/// animates the same key again must survive the finished-key sweep.
@MainActor
@Suite struct AnimationSchedulerTests {
    @Test func landsExactlyOnTargetAndCompletes() {
        let scheduler = AnimationScheduler()
        var value: Float = 0
        var completed = false
        scheduler.animate(key: "k", from: .float(0), to: .float(10), durationFrames: 30,
                          curve: .linear,
                          apply: { if case .float(let current) = $0 { value = current } },
                          onComplete: { completed = true })
        #expect(scheduler.isAnimating)
        scheduler.tick(now: 100.0)   // arms the start time
        scheduler.tick(now: 100.25)  // halfway through 0.5 s
        #expect(abs(value - 5) < 0.01)
        scheduler.tick(now: 100.6)   // past the end
        #expect(value == 10)
        #expect(completed)
        #expect(!scheduler.isAnimating)
    }

    @Test func sameKeyRetargetsFromTheLiveValueWithoutQueueing() {
        let scheduler = AnimationScheduler()
        var value: Float = 0
        let apply: (AnimValue) -> Void = { if case .float(let current) = $0 { value = current } }
        scheduler.animate(key: "k", from: .float(0), to: .float(100), durationFrames: 60,
                          curve: .linear, apply: apply)
        scheduler.tick(now: 0)
        scheduler.tick(now: 0.5)
        #expect(abs(value - 50) < 0.1)
        // Retarget to 0 from the live value: must not chain after the first.
        scheduler.animate(key: "k", from: .float(value), to: .float(0), durationFrames: 30,
                          curve: .linear, apply: apply)
        scheduler.tick(now: 1.0)
        scheduler.tick(now: 1.25)  // halfway of 0.5 s: 50 -> 0 midpoint = 25
        #expect(abs(value - 25) < 0.5)
        scheduler.tick(now: 1.6)
        #expect(value == 0)
        #expect(!scheduler.isAnimating)
    }

    @Test func cancelDropsWithoutCompleting() {
        let scheduler = AnimationScheduler()
        var completed = false
        scheduler.animate(key: "k", from: .float(0), to: .float(1), durationFrames: 60,
                          curve: .linear, apply: { _ in }, onComplete: { completed = true })
        scheduler.cancel(key: "k")
        #expect(!scheduler.isAnimating)
        scheduler.tick(now: 5)
        #expect(!completed)
    }

    @Test func zeroFramesLandsOnTheFirstTick() {
        let scheduler = AnimationScheduler()
        var value: Float = 0
        scheduler.animate(key: "k", from: .float(0), to: .float(7), durationFrames: 0,
                          curve: .linear,
                          apply: { if case .float(let current) = $0 { value = current } })
        scheduler.tick(now: 1)
        #expect(value == 7)
        #expect(!scheduler.isAnimating)
    }

    @Test func completionMayAnimateTheSameKeyAgain() {
        let scheduler = AnimationScheduler()
        var value: Float = 0
        let apply: (AnimValue) -> Void = { if case .float(let current) = $0 { value = current } }
        scheduler.animate(key: "k", from: .float(0), to: .float(1), durationFrames: 6,
                          curve: .linear, apply: apply,
                          onComplete: {
                              scheduler.animate(key: "k", from: .float(1), to: .float(2),
                                                durationFrames: 6, curve: .linear, apply: apply)
                          })
        scheduler.tick(now: 0)
        scheduler.tick(now: 1)  // finishes the first; its completion re-arms "k"
        #expect(value == 1)
        // Before the fix the finished-key sweep ran after the completion and
        // deleted the animation it had just queued.
        #expect(scheduler.isAnimating)
        scheduler.tick(now: 2)
        scheduler.tick(now: 3)
        #expect(value == 2)
        #expect(!scheduler.isAnimating)
    }
}

/// The accumulator behind the YBAR_DEBUG `[ybar:frames]` line (review
/// finding A12), driven with synthetic timestamps: the first tick only opens
/// the window, a closed window reports frames / elapsed, every window starts
/// its count afresh, and a reset keeps an idle gap out of the average.
@Suite struct FrameRateTraceTests {
    private func run(_ trace: inout FrameRateTrace, from start: TimeInterval,
                     hz: Double, seconds: Double) -> [Double] {
        var reported: [Double] = []
        for i in 1...Int(hz * seconds) {
            if let fps = trace.record(now: start + Double(i) / hz) { reported.append(fps) }
        }
        return reported
    }

    @Test func firstTickOpensTheWindowWithoutReporting() {
        var trace = FrameRateTrace(window: 2)
        #expect(trace.record(now: 10) == nil)
        #expect(trace.frames == 0)
        #expect(trace.windowStart == 10)
    }

    @Test func reportsTheSustainedRateOnceTheWindowCloses() {
        var trace = FrameRateTrace(window: 2)
        _ = trace.record(now: 0)
        // 120 Hz for exactly one window: the 240th tick lands on t = 2.
        let reported = run(&trace, from: 0, hz: 120, seconds: 2)
        #expect(reported.count == 1)
        #expect(abs((reported.first ?? 0) - 120) < 0.01)
    }

    @Test func eachWindowStartsItsCountAfresh() {
        var trace = FrameRateTrace(window: 2)
        _ = trace.record(now: 0)
        var reported = run(&trace, from: 0, hz: 120, seconds: 2)
        // The clock drops to 60 Hz: the second window must not carry the
        // first window's 240 ticks into its average.
        reported += run(&trace, from: 2, hz: 60, seconds: 2)
        #expect(reported.count == 2)
        #expect(abs((reported.last ?? 0) - 60) < 0.01)
    }

    @Test func resetKeepsAnIdleGapOutOfTheAverage() {
        var trace = FrameRateTrace(window: 2)
        _ = trace.record(now: 0)
        _ = run(&trace, from: 0, hz: 60, seconds: 1)   // half a window, then the link stops
        trace.reset()
        // The clock restarts 10 s later. Without the reset the 60 ticks above
        // would be spread across the gap and the first report would read ~15.
        #expect(trace.record(now: 10) == nil)
        let reported = run(&trace, from: 10, hz: 60, seconds: 2)
        #expect(reported.count == 1)
        #expect(abs((reported.first ?? 0) - 60) < 0.01)
    }
}
