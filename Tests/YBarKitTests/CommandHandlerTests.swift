import Foundation
import Testing
@testable import YBarKit

/// CLI round trips against the real object model (headless: BarManager
/// without begin(), so no windows are created).
@MainActor
@Suite struct CommandHandlerTests {
    /// CommandHandler's dependencies are plain references; the fixture keeps
    /// them alive for the whole test.
    private struct Stack {
        let barManager: BarManager
        let eventBus: EventBus
        let scheduler: AnimationScheduler
        let handler: CommandHandler
    }

    private func makeStack() throws -> Stack {
        let barManager = try BarManager()
        let eventBus = EventBus()
        eventBus.itemsProvider = { [weak barManager] in barManager?.store.items ?? [] }
        let scheduler = AnimationScheduler()
        let handler = CommandHandler(
            barManager: barManager, eventBus: eventBus,
            scriptRunner: ScriptRunner(), scheduler: scheduler)
        return Stack(barManager: barManager, eventBus: eventBus, scheduler: scheduler, handler: handler)
    }

    private func query(_ stack: Stack, _ name: String) throws -> [String: Any] {
        let text = stack.handler.handle(arguments: ["--query", name])
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    @Test func queryReportsEveryPopupProperty() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--add", "item", "host", "left",
            "--set", "host",
            "popup.align=r", "popup.blur_radius=20", "popup.y_offset=3",
            "popup.horizontal=on", "popup.background.color=0xff102030",
            "popup.background.border_width=2", "popup.background.glass=on",
        ])
        #expect(reply.isEmpty)
        let popup = try #require(try query(stack, "host")["popup"] as? [String: Any])
        #expect(popup["drawing"] as? String == "off")
        #expect(popup["horizontal"] as? Bool == true)
        #expect(popup["align"] as? String == "r")
        #expect((popup["blur_radius"] as? NSNumber)?.floatValue == 20)
        #expect((popup["y_offset"] as? NSNumber)?.floatValue == 3)
        let background = try #require(popup["background"] as? [String: Any])
        #expect(background["color"] as? String == "0xff102030")
        #expect((background["border_width"] as? NSNumber)?.floatValue == 2)
        #expect(background["glass"] as? String == "on")
    }

    /// `--default popup.*` is how themes make every panel glass; it must reach
    /// items added afterwards, while the open state stays per item.
    @Test func popupDefaultsReachNewItems() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--default", "popup.background.color=0xff123456", "popup.blur_radius=30",
            "popup.background.glass=on", "popup.drawing=on",
            "--add", "item", "x", "left",
        ])
        #expect(reply.isEmpty)
        let popup = try #require(try query(stack, "x")["popup"] as? [String: Any])
        #expect(popup["drawing"] as? String == "off")
        #expect((popup["blur_radius"] as? NSNumber)?.floatValue == 30)
        let background = try #require(popup["background"] as? [String: Any])
        #expect(background["color"] as? String == "0xff123456")
        #expect(background["glass"] as? String == "on")
    }

    @Test func addSliderRejectsNonFiniteWidth() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: ["--add", "slider", "s", "left", "inf"])
        #expect(reply.hasPrefix("[!] usage: --add slider"))
        #expect(stack.barManager.store.item(named: "s") == nil)
    }

    @Test func removeCancelsTheItemsAnimations() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--add", "item", "x", "left",
            "--animate", "sin", "60", "--set", "x", "y_offset=10",
        ])
        #expect(reply.isEmpty)
        #expect(stack.scheduler.isAnimating)
        _ = stack.handler.handle(arguments: ["--remove", "x"])
        #expect(!stack.scheduler.isAnimating)
    }

    @Test func cloneCarriesPopupStyling() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--add", "item", "a", "left",
            "--set", "a", "popup.blur_radius=12", "popup.align=c", "popup.drawing=on",
            "--clone", "b", "a",
        ])
        #expect(reply.isEmpty)
        let popup = try #require(try query(stack, "b")["popup"] as? [String: Any])
        #expect((popup["blur_radius"] as? NSNumber)?.floatValue == 12)
        #expect(popup["align"] as? String == "c")
        #expect(popup["drawing"] as? String == "off")
    }
}

/// The verb surface the Windows port pins in command_handler_tests.cpp and
/// audit_regression_tests.cpp, run against the same headless stack: exact
/// error strings, validation order, batch joining, and the tolerance for
/// trailing arguments that sketchybar configs rely on.
@MainActor
@Suite struct CommandHandlerVerbSurfaceTests {
    @MainActor
    private struct Stack {
        let barManager: BarManager
        let eventBus: EventBus
        let scheduler: AnimationScheduler
        let handler: CommandHandler

        func run(_ arguments: [String]) -> String { handler.handle(arguments: arguments) }
        func item(_ name: String) -> Item? { barManager.store.item(named: name) }
    }

    private func makeStack() throws -> Stack {
        let barManager = try BarManager()
        let eventBus = EventBus()
        eventBus.itemsProvider = { [weak barManager] in barManager?.store.items ?? [] }
        let scheduler = AnimationScheduler()
        let handler = CommandHandler(
            barManager: barManager, eventBus: eventBus,
            scriptRunner: ScriptRunner(), scheduler: scheduler)
        return Stack(barManager: barManager, eventBus: eventBus, scheduler: scheduler, handler: handler)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func pingRepliesPongAndUnknownDomainsError() throws {
        let stack = try makeStack()
        #expect(stack.run(["--ping"]) == "pong")
        #expect(stack.run(["--bogus"]) == "[!] unknown domain: --bogus")
    }

    @Test func addSetQueryRoundTrip() throws {
        let stack = try makeStack()
        #expect(stack.run(["--add", "item", "clock", "right"]).isEmpty)
        #expect(stack.run(["--set", "clock", "label=12:00", "label.color=0xffff0000"]).isEmpty)
        #expect(stack.item("clock")?.label.string == "12:00")

        let object = try json(stack.run(["--query", "clock"]))
        #expect(object["name"] as? String == "clock")
        let geometry = try #require(object["geometry"] as? [String: Any])
        #expect(geometry["position"] as? String == "right")
        let label = try #require(object["label"] as? [String: Any])
        #expect(label["color"] as? String == "0xffff0000")
    }

    @Test func addValidatesUsageAndDuplicates() throws {
        let stack = try makeStack()
        #expect(stack.run(["--add"]) == "[!] --add needs a type")
        #expect(stack.run(["--add", "item", "x"]) == "[!] usage: --add item <name> <position>")
        #expect(stack.run(["--add", "item", "x", "nowhere"]) == "[!] invalid position or duplicate name: x nowhere")
        #expect(stack.run(["--add", "item", "x", "left"]).isEmpty)
        #expect(stack.run(["--add", "item", "x", "left"]) == "[!] invalid position or duplicate name: x left")
        #expect(stack.run(["--add", "widget", "x2", "left"])
                == "[!] unknown --add type: widget (supported: item, graph, slider, bracket, event)")
        #expect(stack.run(["--add", "alias", "Foo,Bar"]) == "[!] usage: --add alias \"Owner[,Window]\" <position>")
    }

    @Test func popupMembersRequireAnExistingHost() throws {
        let stack = try makeStack()
        #expect(stack.run(["--add", "item", "row", "popup.missing"])
                == "[!] invalid position or duplicate name: row popup.missing")
        #expect(stack.run(["--add", "item", "host", "left"]).isEmpty)
        #expect(stack.run(["--add", "item", "row", "popup.host"]).isEmpty)
        #expect(stack.item("row")?.popupHost == "host")
        #expect(stack.item("row")?.position == .popup)
    }

    @Test func graphAndSliderAddsReportDuplicatesAndMissingHostsLikeItems() throws {
        let stack = try makeStack()
        _ = stack.run(["--add", "item", "dup", "left"])
        #expect(stack.run(["--add", "graph", "dup", "left", "60"]) == "[!] invalid position or duplicate name: dup left")
        #expect(stack.run(["--add", "slider", "dup", "left", "100"]) == "[!] invalid position or duplicate name: dup left")
        #expect(stack.run(["--add", "graph", "g", "popup.missing", "60"])
                == "[!] invalid position or duplicate name: g popup.missing")
    }

    @Test func graphAddValidatesCapacityAndPushFeedsIt() throws {
        let stack = try makeStack()
        #expect(stack.run(["--add", "graph", "g", "left", "0"])
                == "[!] usage: --add graph <name> <position> <width> (1...8192)")
        #expect(stack.run(["--add", "graph", "g", "left", "60"]).isEmpty)
        // "-0.25" is a value, not a flag: CommandParser.isValue keeps it in the batch.
        #expect(stack.run(["--push", "g", "0.5", "-0.25", "2"]).isEmpty)
        let samples = try #require(stack.item("g")?.graph?.ordered())
        // The ring is pre-filled to capacity, so pushes land at the END.
        #expect(samples.count == 60)
        #expect(samples[57] == 0.5)
        #expect(samples[58] == 0)  // clamped
        #expect(samples[59] == 1)  // clamped
        #expect(stack.run(["--push", "g", "abc"]) == "[!] invalid graph value: abc")
    }

    @Test func bracketsValidateMembersAndEnableBackgroundDrawing() throws {
        let stack = try makeStack()
        #expect(stack.run(["--add", "bracket", "b", "missing"]) == "[!] unknown bracket members: missing")
        #expect(stack.run(["--add", "item", "m1", "left"]).isEmpty)
        #expect(stack.run(["--add", "bracket", "b", "m1"]).isEmpty)
        #expect(stack.item("b")?.kind == .bracket)
        #expect(stack.item("b")?.background.drawing == true)
        // Regex members may match nothing yet (space items appear later).
        #expect(stack.run(["--add", "bracket", "b2", "/space\\..*/"]).isEmpty)
        #expect(stack.run(["--add", "bracket", "b3", "nosuch"]) == "[!] unknown bracket members: nosuch")
    }

    @Test func subscribeValidatesItemAndEventNames() throws {
        let stack = try makeStack()
        #expect(stack.run(["--subscribe", "x", "system_woke"]) == "[!] no item named x")
        #expect(stack.run(["--add", "item", "x", "left"]).isEmpty)
        #expect(stack.run(["--subscribe", "x", "nope"]) == "[!] unknown event: nope")
        #expect(stack.run(["--subscribe", "x", "system_woke", "media_change"]).isEmpty)
        // Same mask the bus hands a direct subscriber to both events.
        let probe = Item(name: "probe", position: .left)
        _ = stack.eventBus.subscribe(item: probe, eventName: "system_woke")
        _ = stack.eventBus.subscribe(item: probe, eventName: "media_change")
        #expect(probe.updateMask != 0)
        #expect(stack.item("x")?.updateMask == probe.updateMask)
    }

    @Test func barAndDefaultDomainsRouteTheirSetters() throws {
        let stack = try makeStack()
        #expect(stack.run(["--bar", "height=32", "color=0xdd1e1e2e"]).isEmpty)
        #expect(stack.barManager.settings.height == 32)
        #expect(stack.barManager.settings.backgroundColor.argb == 0xDD1E_1E2E)
        #expect(stack.run(["--bar", "height"]) == "[!] expected key=value, got: height")
        #expect(stack.run(["--bar", "topmost=maybe"]) == "[!] invalid topmost: maybe")

        #expect(stack.run(["--default", "label.color=0xff00ff00"]).isEmpty)
        #expect(stack.run(["--add", "item", "y", "left"]).isEmpty)
        #expect(stack.item("y")?.label.color.argb == 0xFF00_FF00)
        #expect(stack.run(["--default", "reset"]).isEmpty)
        #expect(stack.run(["--add", "item", "z", "left"]).isEmpty)
        #expect(stack.item("z")?.label.color.argb == 0xFFFF_FFFF)
    }

    @Test func oneMessageBatchesManyDomainsAndJoinsOutputsWithNewlines() throws {
        let stack = try makeStack()
        #expect(stack.run(["--add", "item", "a", "left", "--ping", "--set", "a", "label=hi"]) == "pong")
        #expect(stack.item("a")?.label.string == "hi")
        #expect(stack.run(["--ping", "--query", "nope", "--ping"]) == "pong\n[!] no item named nope\npong")
    }

    @Test func triggerRequiresAnEventNameAndPassesExtras() throws {
        let stack = try makeStack()
        #expect(stack.run(["--trigger"]) == "[!] --trigger needs an event name")
        #expect(stack.run(["--add", "event", "custom_event"]).isEmpty)
        #expect(stack.run(["--add", "item", "listener", "left"]).isEmpty)
        stack.item("listener")?.script = "echo"
        #expect(stack.run(["--subscribe", "listener", "custom_event"]).isEmpty)

        var seen: [String: String] = [:]
        stack.eventBus.runItemScript = { _, environment in seen = environment }
        #expect(stack.run(["--trigger", "custom_event", "INFO=hello", "FOCUSED_WORKSPACE=2"]).isEmpty)
        #expect(seen["INFO"] == "hello")
        #expect(seen["FOCUSED_WORKSPACE"] == "2")
        #expect(seen["SENDER"] == "custom_event")
    }

    @Test func triggerTokensWithoutEqualsAreSkippedNotInjectedAsEmptyVars() throws {
        let stack = try makeStack()
        _ = stack.run(["--add", "item", "x", "left"])
        stack.item("x")?.script = "echo"
        _ = stack.run(["--subscribe", "x", "system_woke"])
        var seen: [String: String] = [:]
        stack.eventBus.runItemScript = { _, environment in seen = environment }
        _ = stack.run(["--trigger", "system_woke", "BARE", "KEY=value"])
        #expect(seen["BARE"] == nil)
        #expect(seen["KEY"] == "value")
    }

    @Test func moveReorderRenameCloneRemoveVerbSurface() throws {
        let stack = try makeStack()
        _ = stack.run(["--add", "item", "a", "left"])
        _ = stack.run(["--add", "item", "b", "left"])
        #expect(stack.run(["--move", "b", "before", "a"]).isEmpty)
        #expect(stack.barManager.store.items.map(\.name) == ["b", "a"])
        #expect(stack.run(["--move", "b", "sideways", "a"]) == "[!] usage: --move <name> before|after <anchor>")
        #expect(stack.run(["--rename", "b", "c"]).isEmpty)
        #expect(stack.run(["--rename", "missing", "x"]) == "[!] could not rename missing")
        #expect(stack.run(["--clone", "c2", "c"]).isEmpty)
        #expect(stack.run(["--clone", "c3", "c", "before"]).isEmpty)
        #expect(stack.barManager.store.items.map(\.name) == ["c3", "c", "a", "c2"])
        // Unknown names are tolerated (dropped); a duplicate cannot be placed.
        #expect(stack.run(["--reorder", "a", "zzz"]).isEmpty)
        #expect(stack.run(["--reorder", "a", "a"]) == "[!] could not reorder (unknown names?)")
        #expect(stack.run(["--remove", "c2"]).isEmpty)
        #expect(stack.run(["--remove", "c2"]) == "[!] no item matching c2")
    }

    @Test func queryValidatesTargetsAndEmitsRealBooleans() throws {
        let stack = try makeStack()
        #expect(stack.run(["--query"]) == "[!] --query needs a target")
        #expect(stack.run(["--query", "nope"]) == "[!] no item named nope")

        let bar = try json(stack.run(["--query", "bar"]))
        #expect(bar["height"] != nil)
        #expect(bar["topmost"] as? String == "off")
        // hidden/sticky/idle_inhibit are JSON booleans, not "on"/"off" strings.
        #expect(bar["hidden"] as? Bool == false)
        #expect(bar["sticky"] as? Bool == true)
        #expect(bar["idle_inhibit"] as? Bool == false)

        let events = try json(stack.run(["--query", "events"]))
        let frontApp = try #require(events["front_app_switched"] as? [String: Any])
        #expect(frontApp["notification"] as? String == "(null)")
    }

    @Test func hotloadValidatesItsBooleanAndReachesTheHook() throws {
        let stack = try makeStack()
        #expect(stack.run(["--hotload", "maybe"]) == "[!] usage: --hotload <on|off>")
        var hotload = false
        stack.handler.onHotloadToggle = { hotload = $0 }
        #expect(stack.run(["--hotload", "on"]).isEmpty)
        #expect(hotload)
    }

    @Test func verbsTolerateTrailingArguments() throws {
        let stack = try makeStack()
        #expect(stack.run(["--add", "item", "a", "left", "extra"]).isEmpty)
        #expect(stack.run(["--query", "bar", "extra"]).contains("\"height\""))
        #expect(stack.run(["--remove", "a", "extra"]).isEmpty)
    }

    @Test func aBadTokenDoesNotDiscardTheRestOfTheBatch() throws {
        let stack = try makeStack()
        _ = stack.run(["--add", "item", "a", "left"])
        #expect(stack.run(["--set", "a", "bogus", "label=hi"]) == "[!] expected key=value, got: bogus")
        #expect(stack.item("a")?.label.string == "hi")
    }
}
