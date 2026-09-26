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

    @Test func barGlassVariantParsesAndQueries() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--bar", "glass=on", "glass_variant=regular",
        ])
        #expect(reply.isEmpty)
        #expect(stack.barManager.settings.glass)
        #expect(stack.barManager.settings.glassVariant == .regular)
        let bar = try query(stack, "bar")
        #expect(bar["glass"] as? String == "on")
        #expect(bar["glass_variant"] as? String == "regular")
        #expect(bar["glass_tint"] as? String == "0x00000000")
    }

    /// `--bar refraction` round-trips through the socket and shows up in
    /// `--query bar`, and a bad token is refused by name rather than silently
    /// turning a capture on.
    @Test func barRefractionParsesAndQueries() throws {
        let stack = try makeStack()
        #expect(try query(stack, "bar")["refraction"] as? String == "off")
        #expect(stack.handler.handle(arguments: ["--bar", "refraction=wallpaper"]).isEmpty)
        #expect(stack.barManager.settings.refraction == .wallpaper)
        #expect(try query(stack, "bar")["refraction"] as? String == "wallpaper")

        let bad = stack.handler.handle(arguments: ["--bar", "refraction=yes"])
        #expect(bad.contains("invalid refraction"))
        #expect(stack.barManager.settings.refraction == .wallpaper)
    }

    /// `default` / `off` restore the built-in `clear` at bar level, the same
    /// tokens that drop the per-item override.
    @Test func barGlassVariantAcceptsDefaultAndOff() throws {
        let stack = try makeStack()
        #expect(stack.handler.handle(arguments: ["--bar", "glass_variant=regular"]).isEmpty)
        #expect(stack.barManager.settings.glassVariant == .regular)
        let reset = stack.handler.handle(arguments: ["--bar", "glass_variant=default"])
        #expect(reset.isEmpty)
        #expect(stack.barManager.settings.glassVariant == .clear)
        #expect(try query(stack, "bar")["glass_variant"] as? String == "clear")
        #expect(stack.handler.handle(arguments: ["--bar", "glass_variant=regular"]).isEmpty)
        let off = stack.handler.handle(arguments: ["--bar", "glass_variant=off"])
        #expect(off.isEmpty)
        #expect(stack.barManager.settings.glassVariant == .clear)
    }

    /// The private `_setVariant:` names (`dock`, `control_center`,
    /// `app_icons`) were removed; they must fail with the accepted list, at
    /// both bar and item level, and leave the previous value alone.
    @Test func glassVariantRejectsRemovedPrivateNames() throws {
        let stack = try makeStack()
        #expect(stack.handler.handle(arguments: ["--bar", "glass_variant=regular"]).isEmpty)
        let bar = stack.handler.handle(arguments: ["--bar", "glass_variant=dock"])
        #expect(bar.contains("invalid glass_variant: dock"))
        #expect(bar.contains("(clear|regular|default|off)"))
        #expect(stack.barManager.settings.glassVariant == .regular)
        for name in ["control_center", "app_icons"] {
            #expect(stack.handler.handle(arguments: ["--bar", "glass_variant=\(name)"])
                .contains("invalid glass_variant: \(name)"))
        }
        #expect(stack.handler.handle(arguments: ["--add", "item", "pill", "left"]).isEmpty)
        let item = try #require(stack.barManager.store.items.first { $0.name == "pill" })
        let set = stack.handler.handle(arguments: ["--set", "pill", "background.glass_variant=dock"])
        #expect(set.contains("invalid glass_variant: dock"))
        #expect(set.contains("(clear|regular|default|off)"))
        #expect(item.background.glassVariant == nil)
    }

    @Test func barGlassTintParsesAndClears() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--bar", "glass_tint=0x40ffffff",
        ])
        #expect(reply.isEmpty)
        #expect(stack.barManager.settings.glassTint.argb == 0x40FF_FFFF)
        let bar = try query(stack, "bar")
        #expect(bar["glass_tint"] as? String == "0x40ffffff")
        let cleared = stack.handler.handle(arguments: ["--bar", "glass_tint=0x00000000"])
        #expect(cleared.isEmpty)
        #expect(stack.barManager.settings.glassTint.argb == 0)
    }

    @Test func itemGlassTintOverridesBarDefault() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--bar", "glass_tint=0x402a2a2a",
            "--add", "item", "pill", "left",
            "--set", "pill", "background.glass_tint=0x80ff0000",
        ])
        #expect(reply.isEmpty)
        let item = try #require(stack.barManager.store.items.first { $0.name == "pill" })
        #expect(item.background.hasGlassTint)
        #expect(item.background.glassTint.argb == 0x80FF_0000)
        let geometry = try #require(try query(stack, "pill")["geometry"] as? [String: Any])
        let background = try #require(geometry["background"] as? [String: Any])
        #expect(background["glass_tint"] as? String == "0x80ff0000")
        let cleared = stack.handler.handle(arguments: [
            "--set", "pill", "background.glass_tint=0x00000000",
        ])
        #expect(cleared.isEmpty)
        #expect(!item.background.hasGlassTint)
        let after = try #require(try query(stack, "pill")["geometry"] as? [String: Any])
        let bg = try #require(after["background"] as? [String: Any])
        #expect(bg["glass_tint"] as? String == "default")
        let popupSet = stack.handler.handle(arguments: [
            "--set", "pill", "popup.background.glass_tint=0x20ffffff",
        ])
        #expect(popupSet.isEmpty)
        #expect(item.popup.background.hasGlassTint)
        #expect(item.popup.background.glassTint.argb == 0x20FF_FFFF)
    }

    @Test func itemGlassVariantOverrideParses() throws {
        let stack = try makeStack()
        let reply = stack.handler.handle(arguments: [
            "--add", "item", "pill", "left",
            "--set", "pill", "background.glass=on", "background.glass_variant=clear",
        ])
        #expect(reply.isEmpty)
        let item = try #require(stack.barManager.store.items.first { $0.name == "pill" })
        #expect(item.background.glass)
        #expect(item.background.glassVariant == .clear)
        let bad = stack.handler.handle(arguments: [
            "--set", "pill", "background.glass_variant=not_a_variant",
        ])
        #expect(bad.contains("invalid glass_variant"))
        let cleared = stack.handler.handle(arguments: [
            "--set", "pill", "background.glass_variant=default",
        ])
        #expect(cleared.isEmpty)
        #expect(item.background.glassVariant == nil)
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

    /// `slider.interactive` is a boolean leaf like any other (on/off/toggle),
    /// is published by --query, and never blocks a percentage set: a
    /// read-only meter is still driven by its script.
    @Test func sliderInteractiveIsSetToggledAndQueried() throws {
        let stack = try makeStack()
        var reply = stack.handler.handle(arguments: [
            "--add", "slider", "s", "left", "80",
            "--set", "s", "slider.interactive=off", "slider.percentage=42",
        ])
        #expect(reply.isEmpty)
        var slider = try #require(try query(stack, "s")["slider"] as? [String: Any])
        #expect(slider["interactive"] as? String == "off")
        #expect((slider["percentage"] as? NSNumber)?.floatValue == 42)

        reply = stack.handler.handle(arguments: ["--set", "s", "slider.interactive=toggle"])
        #expect(reply.isEmpty)
        slider = try #require(try query(stack, "s")["slider"] as? [String: Any])
        #expect(slider["interactive"] as? String == "on")

        reply = stack.handler.handle(arguments: ["--set", "s", "slider.interactive=maybe"])
        #expect(reply.hasPrefix("[!] invalid boolean"))
    }

    /// `background.shadow.blur` is an animatable float leaf, published by
    /// --query next to distance and angle.
    @Test func shadowBlurIsSetAnimatedAndQueried() throws {
        let stack = try makeStack()
        var reply = stack.handler.handle(arguments: [
            "--add", "item", "x", "left",
            "--set", "x", "background.shadow.drawing=on", "background.shadow.blur=4",
        ])
        #expect(reply.isEmpty)
        let geometry = try #require(try query(stack, "x")["geometry"] as? [String: Any])
        let background = try #require(geometry["background"] as? [String: Any])
        let shadow = try #require(background["shadow"] as? [String: Any])
        #expect((shadow["blur"] as? NSNumber)?.floatValue == 4)

        reply = stack.handler.handle(arguments: [
            "--animate", "sin", "30", "--set", "x", "background.shadow.blur=12",
        ])
        #expect(reply.isEmpty)
        #expect(stack.scheduler.isAnimating)
    }

    /// `image.desaturate` toggles like every boolean leaf and `image.y_offset`
    /// animates like every float one; --query publishes both.
    @Test func imageDesaturateAndYOffsetAreSetAndQueried() throws {
        let stack = try makeStack()
        var reply = stack.handler.handle(arguments: [
            "--add", "item", "x", "left",
            "--set", "x", "image.string=sf.circle", "image.desaturate=on", "image.y_offset=2",
        ])
        #expect(reply.isEmpty)
        var image = try #require(try query(stack, "x")["image"] as? [String: Any])
        #expect(image["desaturate"] as? String == "on")
        #expect((image["y_offset"] as? NSNumber)?.floatValue == 2)

        reply = stack.handler.handle(arguments: [
            "--set", "x", "image.desaturate=toggle",
            "--animate", "sin", "30", "--set", "x", "image.y_offset=6",
        ])
        #expect(reply.isEmpty)
        image = try #require(try query(stack, "x")["image"] as? [String: Any])
        #expect(image["desaturate"] as? String == "off")
        #expect(stack.scheduler.isAnimating)
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

    // MARK: - --volume

    /// Headless the hook is nil, so none of these can reach the real output
    /// device; every reply is a validation result.
    @Test func volumeValidatesBeforeTouchingTheDevice() throws {
        let stack = try makeStack()
        #expect(stack.handler.handle(arguments: ["--volume"]).hasPrefix("[!] usage: --volume"))
        #expect(stack.handler.handle(arguments: ["--volume", "101"]) == "[!] invalid volume: 101")
        #expect(stack.handler.handle(arguments: ["--volume", "abc"]) == "[!] invalid volume: abc")
        #expect(stack.handler.handle(arguments: ["--volume", "+x"]) == "[!] invalid volume: +x")
        #expect(stack.handler.handle(arguments: ["--volume", "50", "Music"])
            == "[!] per-app volume is not available on macOS")
        // Well-formed but unwired: the parser accepted it, the hook is missing.
        #expect(stack.handler.handle(arguments: ["--volume", "50"]) == "[!] volume control is not available")
        #expect(stack.handler.handle(arguments: ["--volume", "-4"]) == "[!] volume control is not available")
    }

    @Test func volumeParsesAbsoluteLevelsAndSignedSteps() throws {
        let stack = try makeStack()
        var requests: [CommandHandler.VolumeRequest] = []
        stack.handler.onVolume = { requests.append($0); return true }
        let reply = stack.handler.handle(arguments: [
            "--volume", "50", "--volume", "+4", "--volume", "-3", "--volume", "50.6", "--volume", "0",
        ])
        #expect(reply.isEmpty)
        #expect(requests == [.absolute(50), .step(4), .step(-3), .absolute(51), .absolute(0)])
        stack.handler.onVolume = { _ in false }
        #expect(stack.handler.handle(arguments: ["--volume", "10"])
            == "[!] the output device refused the volume change")
    }

    // MARK: - --query apps / --app

    /// `apps` is a reserved query target like bar/defaults/events/displays:
    /// it shadows an item of that name, sketchybar-style, instead of being
    /// matched after item lookup. One rule, pinned here.
    @Test func queryAppsIsReservedAndShadowsAnItemOfThatName() throws {
        let stack = try makeStack()
        #expect(stack.handler.handle(arguments: ["--add", "item", "apps", "left"]).isEmpty)
        let text = stack.handler.handle(arguments: ["--query", "apps"])
        let rows = try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        for row in rows {
            #expect(Set(row.keys) == ["name", "bundle_id", "pid", "active", "hidden"])
        }
        // The item itself is untouched and still reachable by every other domain.
        #expect(stack.barManager.store.item(named: "apps") != nil)
        #expect(stack.handler.handle(arguments: ["--set", "apps", "label=x"]).isEmpty)
    }

    /// The action is validated before the target is resolved and an unknown
    /// target is reported, so nothing here can reach a real application.
    @Test func appValidatesActionThenTargetWithoutSideEffects() throws {
        let stack = try makeStack()
        #expect(stack.handler.handle(arguments: ["--app"]).hasPrefix("[!] usage: --app"))
        #expect(stack.handler.handle(arguments: ["--app", "com.example.nothing"]).hasPrefix("[!] usage: --app"))
        #expect(stack.handler.handle(arguments: ["--app", "com.example.nothing", "dance"])
            == "[!] unknown --app action: dance (activate|hide|quit|kill)")
        #expect(stack.handler.handle(arguments: ["--app", "com.example.nothing", "activate"])
            == "[!] no running app matching com.example.nothing")
        #expect(CommandHandler.AppControl.resolve("com.example.nothing").isEmpty)
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
