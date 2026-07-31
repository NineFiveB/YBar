import Foundation
import Testing
@testable import YBarKit

/// End-to-end tests of the embedded YbarLua runtime against the real object
/// model (headless: BarManager without begin(), so no windows are created).
@MainActor
@Suite(.serialized) struct LuaRuntimeTests {
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
            .appendingPathComponent("ybar-lua-test-\(UUID().uuidString).lua")
        try? code.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return runtime.runConfig(at: url)
    }

    @Test func barItemAndNestedProperties() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        let error = run("""
        ybar.bar({ height = 40, color = "0xff112233" })
        local clock = ybar.add("item", "clock", "right")
        clock:set({
          label = "hello",
          icon = { color = "0xffff0000", padding_left = 6 },
          ["background.corner_radius"] = 7,
          background = { drawing = true },
        })
        """, stack.runtime)
        #expect(error == nil)
        #expect(stack.barManager.settings.height == 40)
        #expect(stack.barManager.settings.backgroundColor.argb == 0xFF11_2233)

        let clock = stack.barManager.store.item(named: "clock")
        #expect(clock?.position == .right)
        #expect(clock?.label.string == "hello")
        #expect(clock?.icon.color.argb == 0xFFFF_0000)
        #expect(clock?.icon.paddingLeft == 6)
        #expect(clock?.background.cornerRadius == 7)
        #expect(clock?.background.drawing == true)
    }

    @Test func subscriptionCallbackFiresInProcess() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        // Wire the Lua-first dispatch the daemon normally provides.
        stack.eventBus.runItemScript = { [weak runtime = stack.runtime] item, env in
            _ = runtime?.handleEvent(item: item, environment: env)
        }
        let error = run("""
        local w = ybar.add("item", "wifi", "left")
        w:subscribe("wifi_change", function(env)
          w:set({ label = "net:" .. env.INFO })
        end)
        """, stack.runtime)
        #expect(error == nil)

        stack.eventBus.trigger(name: "wifi_change", info: "MyNetwork")
        #expect(stack.barManager.store.item(named: "wifi")?.label.string == "net:MyNetwork")
    }

    @Test func luaOnlyItemsReceiveEventsWithoutShellScript() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        var shellRan = false
        stack.eventBus.runItemScript = { [weak runtime = stack.runtime] item, env in
            if runtime?.handleEvent(item: item, environment: env) == true { return }
            shellRan = true
        }
        let error = run("""
        local i = ybar.add("item", "x", "left")
        i:subscribe("system_woke", function(env) i:set({ label = "woke" }) end)
        """, stack.runtime)
        #expect(error == nil)
        let item = stack.barManager.store.item(named: "x")
        #expect(item?.hasLuaHandlers == true)
        #expect(item?.script.isEmpty == true)

        stack.eventBus.trigger(name: "system_woke")
        #expect(item?.label.string == "woke")
        #expect(!shellRan)
    }

    @Test func componentsAndGraphPush() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        let error = run("""
        local g = ybar.add("graph", "cpu", "right", 4)
        g:push({ 0.25, 0.5 })
        local s = ybar.add("slider", "vol", "right", 80)
        s:set({ slider = { percentage = 66 } })
        local a = ybar.add("item", "a", "left")
        a:set({ label = "m" })
        local br = ybar.add("bracket", "grp", { "a" })
        """, stack.runtime)
        #expect(error == nil)

        let graph = stack.barManager.store.item(named: "cpu")?.graph
        #expect(graph?.capacity == 4)
        #expect(graph?.ordered().suffix(2) == [0.25, 0.5])
        #expect(stack.barManager.store.item(named: "vol")?.slider?.percentage == 66)
        let bracket = stack.barManager.store.item(named: "grp")
        #expect(bracket?.kind == .bracket)
        #expect(bracket?.members == ["a"])
    }

    @Test func animateWrapperScopesContext() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        let error = run("""
        local i = ybar.add("item", "anim", "left")
        i:set({ ["label.color"] = "0xff000000" })
        ybar.animate("linear", 30, function()
          i:set({ ["label.color"] = "0xffffffff" })
        end)
        """, stack.runtime)
        #expect(error == nil)
        // The color set inside animate() must be scheduled, not applied directly.
        #expect(stack.scheduler.isAnimating)
        #expect(stack.runtime.animationContext == nil)
        #expect(stack.barManager.store.item(named: "anim")?.label.color.argb == 0xFF00_0000)
    }

    @Test func configErrorsAreReportedNotFatal() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        let error = run("this is not lua", stack.runtime)
        #expect(error?.contains("lua") == true)
    }
}
