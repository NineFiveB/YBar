import AppKit
import Testing
@testable import YBarKit

// Regression tests for the windowing and input findings of the second
// (Windows-parity) review. Headless: a BarManager without begin() and with an
// empty display list never builds a surface, so nothing is ordered on screen.

@MainActor
private func makeHeadlessManager() throws -> BarManager {
    let manager = try BarManager()
    // Every settings write re-evaluates the display policy; an empty list
    // keeps that from building real bar panels.
    manager.settings.displayPolicy = .list([])
    return manager
}

@MainActor
@Suite(.serialized) struct IdleInhibitTests {
    @Test func assertionSurvivesSettingsResetAndReleasesOnce() throws {
        let manager = try makeHeadlessManager()
        manager.setIdleInhibit(true)
        let held = manager.idleAssertion
        #expect(held != 0)
        #expect(manager.settings.idleInhibit)

        // A second `on` must not stack a second assertion over the first.
        manager.setIdleInhibit(true)
        #expect(manager.idleAssertion == held)

        // Daemon.reload resets the settings while the assertion is still
        // held; `off` after that must still release it.
        manager.settings.idleInhibit = false
        manager.setIdleInhibit(false)
        #expect(manager.idleAssertion == 0)
        #expect(!manager.settings.idleInhibit)

        // And `on` again creates a fresh one rather than being a no-op.
        manager.setIdleInhibit(true)
        #expect(manager.idleAssertion != 0)
        manager.shutdown()
        #expect(manager.idleAssertion == 0)
    }
}

@MainActor
@Suite struct PopupPlacementTests {
    // A 1440-wide screen at x=1440 (second display) with a 25 pt top bar.
    private let screen = CGRect(x: 1440, y: 0, width: 1440, height: 900)
    private let size = CGSize(width: 320, height: 200)

    private func frame(hostX: CGFloat, align: Character, edgeMargin: CGFloat = 7) -> CGRect {
        PopupSurface.frame(
            anchor: CGRect(x: hostX, y: 875, width: 40, height: 25),
            size: size, barPosition: .top, yOffset: 5, align: align,
            screenFrame: screen, edgeMargin: edgeMargin)
    }

    // Literal expectations throughout: this CLT's #expect mis-evaluates a
    // comparison whose right-hand side is literal arithmetic.
    @Test func fittingPopupIsLeftWhereAlignmentPutsIt() {
        let centred = frame(hostX: 2000, align: "c")
        #expect(centred.minX == 1860)   // host midX 2020 - 160
        #expect(centred.minY == 670)    // 875 - 200 - yOffset 5
        #expect(frame(hostX: 2000, align: "l").minX == 2000)
        #expect(frame(hostX: 2000, align: "r").minX == 1720)   // host maxX 2040 - 320
    }

    @Test func rightEdgeHostIsPulledInsideByTheMargin() {
        // A centred 320 pt popup on the rightmost pill would spill 140 pt
        // past the screen; it must stop `edgeMargin` short of the edge.
        let clamped = frame(hostX: 2860, align: "c", edgeMargin: 12)
        #expect(clamped.maxX == 2868)   // screen maxX 2880 - 12
        #expect(clamped.width == 320)
    }

    @Test func leftEdgeHostIsPushedInsideByTheMargin() {
        let clamped = frame(hostX: 1450, align: "r")
        #expect(clamped.minX == 1447)   // screen minX 1440 + 7
    }

    @Test func widerThanScreenLandsOnTheLeftMarginAndOverflowsRight() {
        let wide = PopupSurface.frame(
            anchor: CGRect(x: 2000, y: 875, width: 40, height: 25),
            size: CGSize(width: 1600, height: 100), barPosition: .top, yOffset: 0,
            align: "c", screenFrame: screen, edgeMargin: 7)
        #expect(wide.minX == 1447)
    }

    @Test func verticalPlacementIsUntouched() {
        let below = frame(hostX: 2860, align: "c")
        #expect(below.minY == 670)
        let above = PopupSurface.frame(
            anchor: CGRect(x: 2860, y: 0, width: 40, height: 25), size: size,
            barPosition: .bottom, yOffset: 5, align: "c", screenFrame: screen, edgeMargin: 7)
        #expect(above.minY == 30)   // host maxY 25 + yOffset 5
    }
}

@Suite struct ScrollStepperTests {
    @Test func wheelNotchesPassThroughUnchanged() {
        var stepper = ScrollStepper()
        #expect(stepper.delta(scrollingDeltaY: 1, precise: false, gestureBegan: false) == 1)
        #expect(stepper.delta(scrollingDeltaY: -3, precise: false, gestureBegan: false) == -3)
    }

    @Test func trackpadSamplesAccumulateToOneStepPerTenPoints() {
        var stepper = ScrollStepper()
        // Three 3 pt samples (9 pt) stay silent; the 2 pt one crosses 10.
        #expect(stepper.delta(scrollingDeltaY: 3, precise: true, gestureBegan: true) == nil)
        #expect(stepper.delta(scrollingDeltaY: 3, precise: true, gestureBegan: false) == nil)
        #expect(stepper.delta(scrollingDeltaY: 3, precise: true, gestureBegan: false) == nil)
        #expect(stepper.delta(scrollingDeltaY: 2, precise: true, gestureBegan: false) == 1)
        // The 1 pt remainder carries: 9 more points is the next step.
        #expect(stepper.delta(scrollingDeltaY: 9, precise: true, gestureBegan: false) == 1)
    }

    @Test func fastSampleEmitsItsWholeStepCountAtOnce() {
        var stepper = ScrollStepper()
        #expect(stepper.delta(scrollingDeltaY: -35, precise: true, gestureBegan: true) == -3)
        // -5 pt remainder; a further -5 completes the fourth step.
        #expect(stepper.delta(scrollingDeltaY: -5, precise: true, gestureBegan: false) == -1)
    }

    @Test func directionReversalCancelsTheRemainder() {
        var stepper = ScrollStepper()
        #expect(stepper.delta(scrollingDeltaY: 8, precise: true, gestureBegan: true) == nil)
        #expect(stepper.delta(scrollingDeltaY: -12, precise: true, gestureBegan: false) == nil)
        #expect(stepper.delta(scrollingDeltaY: -7, precise: true, gestureBegan: false) == -1)
    }

    @Test func newGestureDropsThePreviousTail() {
        var stepper = ScrollStepper()
        #expect(stepper.delta(scrollingDeltaY: 8, precise: true, gestureBegan: true) == nil)
        // 8 pt pending from the last swipe must not turn this 3 pt nudge
        // into a step.
        #expect(stepper.delta(scrollingDeltaY: 3, precise: true, gestureBegan: true) == nil)
    }
}
