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
