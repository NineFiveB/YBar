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
