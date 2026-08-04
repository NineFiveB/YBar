import Foundation
import Testing
@testable import YBarKit

// MARK: - Wire format

@Suite struct WireFormatTests {
    @Test func argvRoundTrip() {
        let arguments = ["--set", "clock", "label=hello world", "icon.color=0xffff0000"]
        let payload = WireFormat.encode(arguments: arguments)
        #expect(WireFormat.decode(payload: payload) == arguments)
    }

    @Test func emptyArgv() {
        let payload = WireFormat.encode(arguments: [])
        #expect(WireFormat.decode(payload: payload).isEmpty)
    }

    @Test func framing() {
        let payload = Data("hello".utf8)
        let framed = WireFormat.frame(payload)
        #expect(framed.count == payload.count + 4)
        #expect(WireFormat.frameLength(header: framed) == 5)
    }

    @Test func oversizedFrameRejected() {
        var length = UInt32(WireFormat.maxFrameLength + 1).littleEndian
        let header = withUnsafeBytes(of: &length) { Data($0) }
        #expect(WireFormat.frameLength(header: header) == nil)
    }
}

// MARK: - Command parsing

@Suite struct CommandParserTests {
    @Test func batchesSplitOnDomains() {
        let batches = CommandParser.batches(from: [
            "--add", "item", "clock", "right",
            "--set", "clock", "label=12:00", "icon.color=0xffffffff",
            "--subscribe", "clock", "system_woke",
        ])
        #expect(batches.count == 3)
        #expect(batches[0] == CommandParser.Batch(domain: "add", args: ["item", "clock", "right"]))
        #expect(batches[1].domain == "set")
        #expect(batches[1].args == ["clock", "label=12:00", "icon.color=0xffffffff"])
        #expect(batches[2].domain == "subscribe")
    }

    @Test func negativeNumbersAreValues() {
        let batches = CommandParser.batches(from: ["--push", "graph", "-0.5"])
        #expect(batches[0].args == ["graph", "-0.5"])
    }

    @Test func keyValueSplitsOnFirstEquals() {
        let pair = CommandParser.keyValue("label=a=b")
        #expect(pair?.key == "label")
        #expect(pair?.value == "a=b")
        #expect(CommandParser.keyValue("noequals") == nil)
    }
}

// MARK: - Colors

@Suite struct ColorTests {
    @Test func parseHex() {
        let color = YColor.parse("0xff112233")
        #expect(color != nil)
        #expect(color?.argb == 0xFF11_2233)
        #expect(abs((color?.alpha ?? 0) - 1.0) < 0.001)
    }

    @Test func rejectGarbage() {
        #expect(YColor.parse("#ffffff") == nil)
        #expect(YColor.parse("red") == nil)
    }

    @Test func lerpEndpoints() {
        let a = YColor(argb: 0xFF00_0000)
        let b = YColor(argb: 0xFFFF_FFFF)
        #expect(YColor.lerp(a, b, 0).argb == a.argb)
        #expect(YColor.lerp(a, b, 1).argb == b.argb)
    }
}

// MARK: - Curves

@Suite struct CurveTests {
    @Test func allCurvesHitEndpoints() {
        let curves: [AnimationCurve] = [.linear, .quadratic, .sin, .tanh, .exp, .circ, .bounce, .overshoot]
        for curve in curves {
            #expect(abs(curve.value(0)) < 0.05, "curve \(curve) at 0")
            #expect(abs(curve.value(1) - 1) < 0.05, "curve \(curve) at 1")
        }
    }

    @Test func firstLetterParsing() {
        #expect(AnimationCurve.parse("tanh") == .tanh)
        #expect(AnimationCurve.parse("sin") == .sin)
        #expect(AnimationCurve.parse("bounce") == .bounce)
        #expect(AnimationCurve.parse("nonsense") == .linear)
    }
}

// MARK: - Fonts & positions

@Suite struct StyleParsingTests {
    @Test func fontSpecParsing() {
        var font = FontSpec()
        font.apply("Hack Nerd Font:Bold:14.0")
        #expect(font.family == "Hack Nerd Font")
        #expect(font.style == "Bold")
        #expect(font.size == 14.0)

        font.apply(":Regular:")
        #expect(font.family == "Hack Nerd Font")
        #expect(font.style == "Regular")
        #expect(font.size == 14.0)
    }

    @Test func positionParsing() {
        #expect(ItemPosition.parse("left") == .left)
        #expect(ItemPosition.parse("q") == .centerLeft)
        #expect(ItemPosition.parse("center_right") == .centerRight)
        #expect(ItemPosition.parse("bogus") == nil)
    }
}

// MARK: - Layout

@MainActor
@Suite struct LayoutTests {
    private func makeItem(_ name: String, _ position: ItemPosition,
                          label: String = "x") -> Item {
        let item = Item(name: name, position: position)
        item.label.string = label
        return item
    }

    private let fixedMeasure: (Item) -> MeasuredContent = { _ in
        MeasuredContent(iconSize: .zero, labelSize: CGSize(width: 50, height: 14))
    }

    @Test func leftItemsFlowRight() {
        let a = makeItem("a", .left)
        let b = makeItem("b", .left)
        var settings = BarSettings()
        settings.paddingLeft = 10
        Layout.perform(items: [a, b], barSize: CGSize(width: 1000, height: 30),
                       settings: settings, measure: fixedMeasure)
        #expect(a.frame.minX == 10)
        #expect(b.frame.minX == 60)
        #expect(a.frame.height == 30)
    }

    @Test func rightItemsFlowLeft() {
        let a = makeItem("a", .right)
        let b = makeItem("b", .right)
        Layout.perform(items: [a, b], barSize: CGSize(width: 1000, height: 30),
                       settings: BarSettings(), measure: fixedMeasure)
        #expect(a.frame.maxX == 1000)
        #expect(b.frame.maxX == 950)
    }

    @Test func centerBlockIsCentered() {
        let a = makeItem("a", .center)
        let b = makeItem("b", .center)
        Layout.perform(items: [a, b], barSize: CGSize(width: 1000, height: 30),
                       settings: BarSettings(), measure: fixedMeasure)
        // Two 50-wide items → block spans 100 centered at 500.
        #expect(a.frame.minX == 450)
        #expect(b.frame.maxX == 550)
    }

    @Test func notchCursorsAvoidDeadZone() {
        let q = makeItem("q", .centerLeft)
        let e = makeItem("e", .centerRight)
        var settings = BarSettings()
        settings.notchWidth = 200
        Layout.perform(items: [q, e], barSize: CGSize(width: 1000, height: 30),
                       settings: settings, measure: fixedMeasure)
        #expect(q.frame.maxX == 400)
        #expect(e.frame.minX == 600)
    }

    @Test func notchWidthOverrideBeatsSettings() {
        let q = makeItem("q", .centerLeft)
        let e = makeItem("e", .centerRight)
        var settings = BarSettings()
        settings.notchWidth = 200
        // Per-surface override: an un-notched display passes 0 and the
        // center flows meet in the middle regardless of the setting.
        Layout.perform(items: [q, e], barSize: CGSize(width: 1000, height: 30),
                       settings: settings, notchWidth: 0, measure: fixedMeasure)
        #expect(q.frame.maxX == 500)
        #expect(e.frame.minX == 500)
        // A notched display passes its physical width when the setting is 0.
        Layout.perform(items: [q, e], barSize: CGSize(width: 1000, height: 30),
                       settings: settings, notchWidth: 300, measure: fixedMeasure)
        #expect(q.frame.maxX == 350)
        #expect(e.frame.minX == 650)
    }

    @Test func fixedWidthOverridesContent() {
        let a = makeItem("a", .left)
        a.customWidth = 200
        Layout.perform(items: [a], barSize: CGSize(width: 1000, height: 30),
                       settings: BarSettings(), measure: fixedMeasure)
        #expect(a.frame.width == 200)
    }

    @Test func invisibleItemsTakeNoSpace() {
        let hidden = makeItem("hidden", .left)
        hidden.drawing = false
        let visible = makeItem("visible", .left)
        Layout.perform(items: [hidden, visible], barSize: CGSize(width: 1000, height: 30),
                       settings: BarSettings(), measure: fixedMeasure)
        #expect(hidden.frame == .zero)
        #expect(visible.frame.minX == 0)
    }
}

// MARK: - Property setting

@MainActor
@Suite struct PropertySetterTests {
    private func makeContext() -> PropertyContext {
        PropertyContext(scheduler: AnimationScheduler(), invalidate: {})
    }

    @Test func dottedPathsReachLeaves() {
        let item = Item(name: "test", position: .left)
        let ctx = makeContext()
        #expect(PropertySetter.set(item: item, property: "icon", value: "hello", context: ctx) == nil)
        #expect(item.icon.string == "hello")

        #expect(PropertySetter.set(item: item, property: "label.color", value: "0xff112233", context: ctx) == nil)
        #expect(item.label.color.argb == 0xFF11_2233)

        #expect(PropertySetter.set(
            item: item, property: "background.shadow.color", value: "0x80000000", context: ctx) == nil)
        #expect(item.background.shadow.color.argb == 0x8000_0000)

        #expect(PropertySetter.set(
            item: item, property: "icon.background.corner_radius", value: "6", context: ctx) == nil)
        #expect(item.icon.background.cornerRadius == 6)
    }

    @Test func colorChannelsAreAddressable() {
        let item = Item(name: "test", position: .left)
        let ctx = makeContext()
        _ = PropertySetter.set(item: item, property: "label.color", value: "0xff000000", context: ctx)
        #expect(PropertySetter.set(item: item, property: "label.color.alpha", value: "0.5", context: ctx) == nil)
        #expect(abs(item.label.color.alpha - 0.5) < 0.001)
    }

    @Test func fontPaths() {
        let item = Item(name: "test", position: .left)
        let ctx = makeContext()
        _ = PropertySetter.set(item: item, property: "label.font", value: "Menlo:Bold:12", context: ctx)
        #expect(item.label.font.family == "Menlo")
        _ = PropertySetter.set(item: item, property: "label.font.size", value: "16", context: ctx)
        #expect(item.label.font.size == 16)
    }

    @Test func widthDynamicResetsToNegative() {
        let item = Item(name: "test", position: .left)
        let ctx = makeContext()
        _ = PropertySetter.set(item: item, property: "width", value: "120", context: ctx)
        #expect(item.customWidth == 120)
        _ = PropertySetter.set(item: item, property: "width", value: "dynamic", context: ctx)
        #expect(item.customWidth == -1)
    }

    @Test func booleansAndToggles() {
        let item = Item(name: "test", position: .left)
        let ctx = makeContext()
        _ = PropertySetter.set(item: item, property: "drawing", value: "off", context: ctx)
        #expect(item.drawing == false)
        _ = PropertySetter.set(item: item, property: "drawing", value: "toggle", context: ctx)
        #expect(item.drawing == true)
    }

    @Test func unknownPropertyReported() {
        let item = Item(name: "test", position: .left)
        let ctx = makeContext()
        let error = PropertySetter.set(item: item, property: "bogus.path", value: "1", context: ctx)
        #expect(error?.contains("unknown") == true)
    }

    @Test func displayAssociationMask() {
        let item = Item(name: "test", position: .left)
        let ctx = makeContext()
        _ = PropertySetter.set(item: item, property: "display", value: "1,3", context: ctx)
        #expect(item.associatedDisplayMask == 0b101)
    }
}

// MARK: - Item store

@MainActor
@Suite struct ItemStoreTests {
    @Test func defaultsPrototypeApplies() {
        let store = ItemStore()
        let scheduler = AnimationScheduler()
        let ctx = PropertyContext(scheduler: scheduler, invalidate: {})
        _ = PropertySetter.set(item: store.defaults, property: "icon.color",
                               value: "0xff123456", context: ctx)
        _ = PropertySetter.set(item: store.defaults, property: "padding_left",
                               value: "8", context: ctx)

        let item = store.add(name: "new", position: .left)
        #expect(item?.icon.color.argb == 0xFF12_3456)
        #expect(item?.paddingLeft == 8)
    }

    @Test func duplicateNamesRejected() {
        let store = ItemStore()
        #expect(store.add(name: "x", position: .left) != nil)
        #expect(store.add(name: "x", position: .right) == nil)
    }

    @Test func removeByName() {
        let store = ItemStore()
        _ = store.add(name: "x", position: .left)
        #expect(store.remove(name: "x"))
        #expect(!store.remove(name: "x"))
    }
}

// MARK: - Event bus

@MainActor
@Suite struct EventBusTests {
    @Test func builtinsAreRegistered() {
        let bus = EventBus()
        #expect(bus.bit(for: "front_app_switched") == 1)
        #expect(bus.bit(for: "space_change") == 2)
        #expect(bus.bit(for: "nonexistent") == nil)
    }

    @Test func subscriptionRoutesTrigger() {
        let bus = EventBus()
        let item = Item(name: "test", position: .left)
        item.script = "echo hi"
        bus.itemsProvider = { [item] }

        var ran: [String: String] = [:]
        bus.runItemScript = { _, env in ran = env }

        #expect(bus.subscribe(item: item, eventName: "system_woke") == nil)
        bus.trigger(name: "system_woke", info: "payload")
        #expect(ran["SENDER"] == "system_woke")
        #expect(ran["INFO"] == "payload")
        #expect(ran["NAME"] == "test")

        ran = [:]
        bus.trigger(name: "space_change", info: "")
        #expect(ran.isEmpty)
    }

    @Test func customEventsAppend() {
        let bus = EventBus()
        #expect(bus.addEvent(name: "my_event") == nil)
        #expect(bus.bit(for: "my_event") != nil)
        // Duplicate add is a no-op, not an error.
        #expect(bus.addEvent(name: "my_event") == nil)
    }
}
