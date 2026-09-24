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
            if let report = trace.record(now: start + Double(i) / hz) { reported.append(report.fps) }
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

    /// The sustained rate alone cannot tell a smooth 120 from a juddering
    /// one: it counts delivered ticks over elapsed time, so a clean run and a
    /// run that dropped every other frame and made it up elsewhere both read
    /// 120.0. These are the fields that separate them.
    @Test func aCleanRunMissesNothingAndKeepsTheGapAtOneInterval() throws {
        var trace = FrameRateTrace(window: 2)
        let interval = 1.0 / 120
        _ = trace.record(now: 0, interval: interval, cost: 0)
        var report: FrameRateTrace.Report?
        for tick in 1...240 {
            if let closed = trace.record(now: Double(tick) * interval,
                                         interval: interval, cost: 0.0002) {
                report = closed
            }
        }
        let closed = try #require(report)
        #expect(abs(closed.fps - 120) < 0.01)
        #expect(abs(closed.linkHz - 120) < 0.01)
        #expect(closed.missed == 0)
        #expect(abs(closed.maxGap - interval) < 1e-9)
        #expect(abs(closed.p99Cost - 0.0002) < 1e-9)
        #expect(abs(closed.budget - interval) < 1e-9)
    }

    @Test func aSkippedVsyncIsCountedAndWidensTheWorstGap() throws {
        var trace = FrameRateTrace(window: 1)
        let interval = 1.0 / 120
        _ = trace.record(now: 0, interval: interval, cost: 0)
        var now = 0.0
        var report: FrameRateTrace.Report?
        for tick in 1...240 {
            // One callback arrives three intervals late: two vsyncs missed.
            now += tick == 60 ? 3 * interval : interval
            if let closed = trace.record(now: now, interval: interval, cost: 0.0001),
               report == nil {
                report = closed
            }
        }
        let closed = try #require(report)
        #expect(closed.missed == 2)
        #expect(abs(closed.maxGap - 3 * interval) < 1e-9)
    }

    /// Core Animation arbitrates the cadence: a 60-120 request can be answered
    /// with 60 at any moment. Counting misses across that change would report
    /// a run of phantom drops, so the change opens a fresh window instead.
    @Test func aCadenceChangeOpensAFreshWindowInsteadOfCountingPhantomMisses() {
        var trace = FrameRateTrace(window: 2)
        let fast = 1.0 / 120
        let slow = 1.0 / 60
        _ = trace.record(now: 0, interval: fast, cost: 0)
        for tick in 1...120 { _ = trace.record(now: Double(tick) * fast, interval: fast, cost: 0) }
        // The link drops to 60 Hz: the first 60 Hz gap is two 120 Hz
        // intervals wide and must not read as one missed vsync.
        #expect(trace.record(now: 1 + slow, interval: slow, cost: 0) == nil)
        #expect(trace.frames == 0)
        var report: FrameRateTrace.Report?
        for tick in 1...121 {
            if let closed = trace.record(now: 1 + slow + Double(tick) * slow,
                                         interval: slow, cost: 0) {
                report = closed
            }
        }
        #expect(report?.missed == 0)
        #expect(abs((report?.linkHz ?? 0) - 60) < 0.01)
    }
}
