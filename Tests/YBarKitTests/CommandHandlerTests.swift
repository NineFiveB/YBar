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
