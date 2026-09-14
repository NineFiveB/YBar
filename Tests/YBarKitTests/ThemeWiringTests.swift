import Foundation
import Testing
@testable import YBarKit

/// Wiring checks on the SHIPPED example themes: the sketchybar-port helpers
/// run through the real Lua runtime, headless (BarManager without begin(),
/// so no windows are created). The themes are the first thing a new user
/// runs, and their interaction wiring has no other coverage.
@MainActor
@Suite(.serialized) struct ThemeWiringTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var portRoot: URL { repoRoot.appendingPathComponent("examples/sketchybar-port") }

    /// The runtime holds barManager/eventBus/scheduler `unowned`, so the
    /// stack has to outlive it — every member is retained here on purpose.
    private struct Stack {
        let barManager: BarManager
        let eventBus: EventBus
        let scheduler: AnimationScheduler
        let runtime: LuaRuntime
    }

    private func makeStack() throws -> Stack {
        let barManager = try BarManager()
        let eventBus = EventBus()
        eventBus.itemsProvider = { [weak barManager] in barManager?.store.items ?? [] }
        let scheduler = AnimationScheduler()
        let runtime = LuaRuntime(barManager: barManager, eventBus: eventBus, scheduler: scheduler)
        return Stack(barManager: barManager, eventBus: eventBus, scheduler: scheduler, runtime: runtime)
    }

    private func run(_ code: String, _ runtime: LuaRuntime) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ybar-theme-test-\(UUID().uuidString).lua")
        try? code.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return runtime.runConfig(at: url)
    }

    /// A multi-line popup cell (device name over connection status) is ONE
    /// click target, so hovering either line must light both plates.
    ///
    /// The regression this pins: the runtime keeps exactly one callback per
    /// (item, event) — LuaRuntime.subscribe unrefs the previous one — so
    /// wiring the cell as "each row hovers itself, plus each row hovers its
    /// sibling" left only the sibling handler alive and every line lit its
    /// neighbour instead of itself.
    @Test func hoverGroupLightsEveryRowInTheCellFromEitherRow() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        let error = run("""
        package.path = "\(Self.portRoot.path)/?.lua;" .. package.path
        sbar = require("sketchybar")
        -- Land fades immediately: this test pins WHICH plates a hover drives,
        -- not the curve the engine drives them with.
        sbar.animate = function(_, _, fn) fn() end
        local hover = require("helpers.hover")
        local name = sbar.add("item", "dev.1", {})
        local status = sbar.add("item", "devstatus.1", {})
        hover.rowGroup({ name, status })
        """, stack.runtime)
        #expect(error == nil)

        let name = try #require(stack.barManager.store.item(named: "dev.1"))
        let status = try #require(stack.barManager.store.item(named: "devstatus.1"))
        let hoverTone: UInt32 = 0x16FF_FFFF   // colors.row_hover
        #expect(name.background.color.argb == 0)
        #expect(status.background.color.argb == 0)

        for hovered in [name, status] {
            #expect(stack.runtime.handleEvent(item: hovered,
                                              environment: ["SENDER": "mouse.entered"]))
            #expect(name.background.color.argb == hoverTone,
                    "hovering \(hovered.name) must light the name row")
            #expect(status.background.color.argb == hoverTone,
                    "hovering \(hovered.name) must light the status row")

            #expect(stack.runtime.handleEvent(item: hovered,
                                              environment: ["SENDER": "mouse.exited"]))
            #expect(name.background.color.argb == 0)
            #expect(status.background.color.argb == 0)
        }
    }

    /// The Bluetooth popup's paired cells must be wired by a SINGLE hover
    /// call. Two calls naming the same rows is the shape that silently loses
    /// a subscription, and the symptom (a highlight one line off) is easy to
    /// reintroduce and hard to spot in a diff.
    @Test func pairedBluetoothRowsTakeExactlyOneHoverRegistration() throws {
        let source = try String(
            contentsOf: Self.portRoot.appendingPathComponent("items/widgets/bluetooth.lua"),
            encoding: .utf8)
        let hoverCalls = source.split(separator: "\n").filter {
            $0.contains("hover.") && $0.contains("paired_")
        }
        #expect(hoverCalls.count == 1, "paired rows wired by \(hoverCalls.count) hover calls")
    }
}
