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
