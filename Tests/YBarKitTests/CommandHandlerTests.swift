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
}
