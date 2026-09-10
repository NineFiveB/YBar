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

@MainActor
private func mouse(_ kind: MouseEventKind, x: CGFloat = 50) -> MouseEventInfo {
    MouseEventInfo(kind: kind, point: CGPoint(x: x, y: 10), button: "left",
                   modifier: "none", scrollDelta: 0)
}

@MainActor
@Suite(.serialized) struct StaleSliderDragTests {
    private let slot = CGRect(x: 0, y: 0, width: 100, height: 25)

    /// A bar surface whose panel is created but never ordered on screen.
    private func makeSurface() throws -> BarSurface {
        let screen = try #require(NSScreen.screens.first)
        return BarSurface(screen: screen, arrangementIndex: 1)
    }

    private func addSlider(to manager: BarManager, frames: inout [(itemID: Int, frame: CGRect)]) throws -> Item {
        let slider = try #require(manager.store.add(name: "vol", position: .left))
        slider.slider = SliderState(width: 80)
        frames = [(slider.id, slot)]
        return slider
    }

    /// Simulate reload / --remove mid-drag: the slider is gone and a plain
    /// item now occupies the same slot.
    private func replaceWithPlainItem(in manager: BarManager, frames: inout [(itemID: Int, frame: CGRect)]) throws -> Item {
        manager.store.removeAll()
        let plain = try #require(manager.store.add(name: "plain", position: .left))
        frames = [(plain.id, slot)]
        return plain
    }

    @Test func barReleaseAfterRemovalIsNotAClick() throws {
        let manager = try makeHeadlessManager()
        let surface = try makeSurface()
        let slider = try addSlider(to: manager, frames: &surface.itemFrames)
        manager.handleMouse(mouse(.down), on: surface)
        #expect(manager.draggingSliderID == slider.id)

        let plain = try replaceWithPlainItem(in: manager, frames: &surface.itemFrames)
        var clicked: [String] = []
        manager.onItemClicked = { item, _ in clicked.append(item.name) }
        manager.handleMouse(mouse(.clicked), on: surface)
        #expect(clicked.isEmpty)
        #expect(manager.draggingSliderID == nil)

        // The next release is an ordinary click again.
        manager.handleMouse(mouse(.clicked), on: surface)
        #expect(clicked == [plain.name])
    }

    @Test func barDragAfterRemovalDropsTheStaleID() throws {
        let manager = try makeHeadlessManager()
        let surface = try makeSurface()
        _ = try addSlider(to: manager, frames: &surface.itemFrames)
        manager.handleMouse(mouse(.down), on: surface)
        _ = try replaceWithPlainItem(in: manager, frames: &surface.itemFrames)
        manager.handleMouse(mouse(.dragged, x: 60), on: surface)
        #expect(manager.draggingSliderID == nil)
    }

    @Test func popupReleaseAfterRemovalIsNotAClick() throws {
        let manager = try makeHeadlessManager()
        let popup = PopupSurface(hostItemID: -1, device: manager.device)
        let slider = try addSlider(to: manager, frames: &popup.itemFrames)
        manager.handlePopupMouse(mouse(.down), on: popup)
        #expect(manager.draggingSliderID == slider.id)

        _ = try replaceWithPlainItem(in: manager, frames: &popup.itemFrames)
        var clicked: [String] = []
        manager.onItemClicked = { item, _ in clicked.append(item.name) }
        manager.handlePopupMouse(mouse(.clicked), on: popup)
        #expect(clicked.isEmpty)
        #expect(manager.draggingSliderID == nil)
        manager.handlePopupMouse(mouse(.clicked), on: popup)
        #expect(clicked == ["plain"])
    }

    @Test func popupDragAfterRemovalDropsTheStaleID() throws {
        let manager = try makeHeadlessManager()
        let popup = PopupSurface(hostItemID: -1, device: manager.device)
        _ = try addSlider(to: manager, frames: &popup.itemFrames)
        manager.handlePopupMouse(mouse(.down), on: popup)
        _ = try replaceWithPlainItem(in: manager, frames: &popup.itemFrames)
        manager.handlePopupMouse(mouse(.dragged, x: 60), on: popup)
        #expect(manager.draggingSliderID == nil)
    }
}

@MainActor
@Suite(.serialized) struct HoverReleaseTests {
    /// The contract every panel-teardown path relies on: the hovered row gets
    /// exactly one targeted mouse.exited, and nothing on a second release.
    @Test func popupReleaseFiresOneExitAndClearsState() throws {
        let manager = try makeHeadlessManager()
        let popup = PopupSurface(hostItemID: -1, device: manager.device)
        let row = try #require(manager.store.add(name: "row", position: .popup))
        popup.itemFrames = [(row.id, CGRect(x: 0, y: 0, width: 100, height: 25))]
        var events: [(String, Bool)] = []
        manager.onItemHover = { item, entered in events.append((item.name, entered)) }

        manager.handlePopupMouse(mouse(.moved), on: popup)
        #expect(popup.hoveredItemID == row.id)
        #expect(row.mouseOver)

        manager.releaseHover(in: popup)
        #expect(popup.hoveredItemID == nil)
        #expect(!row.mouseOver)
        manager.releaseHover(in: popup)
        #expect(events.map(\.0) == ["row", "row"])
        #expect(events.map(\.1) == [true, false])
    }

    @Test func barReleaseFiresOneExitAndClearsState() throws {
        let manager = try makeHeadlessManager()
        let screen = try #require(NSScreen.screens.first)
        let surface = BarSurface(screen: screen, arrangementIndex: 1)
        let item = try #require(manager.store.add(name: "clock", position: .right))
        surface.itemFrames = [(item.id, CGRect(x: 0, y: 0, width: 100, height: 25))]
        var exits = 0
        manager.onItemHover = { _, entered in if !entered { exits += 1 } }

        manager.handleMouse(mouse(.moved), on: surface)
        #expect(surface.hoveredItemID == item.id)

        manager.releaseHover(on: surface)
        manager.releaseHover(on: surface)
        #expect(surface.hoveredItemID == nil)
        #expect(!item.mouseOver)
        #expect(exits == 1)
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
