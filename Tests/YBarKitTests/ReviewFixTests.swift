import Foundation
import IOKit.ps
import Testing
@testable import YBarKit

// Regression tests for the findings of the v0.1 adversarial review.

@MainActor
@Suite struct EventGatingTests {
    private func makeSubscribedItem(_ bus: EventBus) -> Item {
        let item = Item(name: "gated", position: .left)
        item.script = "echo hi"
        item.label.string = "visible"
        _ = bus.subscribe(item: item, eventName: "volume_change")
        return item
    }

    @Test func updatesOffSuppressesEventScripts() {
        let bus = EventBus()
        let item = makeSubscribedItem(bus)
        bus.itemsProvider = { [item] }
        var ran = false
        bus.runItemScript = { _, _ in ran = true }

        item.updatePolicy = .off
        bus.trigger(name: "volume_change", info: "50")
        #expect(!ran)

        item.updatePolicy = .on
        bus.trigger(name: "volume_change", info: "50")
        #expect(ran)
    }

    @Test func whenShownGatesOnDrawingNotContent() {
        let bus = EventBus()
        let item = makeSubscribedItem(bus)
        bus.itemsProvider = { [item] }
        var ran = false
        bus.runItemScript = { _, _ in ran = true }

        item.updatePolicy = .whenShown
        item.drawing = false
        bus.trigger(name: "volume_change", info: "50")
        #expect(!ran)

        // Empty content but drawing=on must still receive updates (the update
        // is what populates the item — sketchybar semantics).
        item.drawing = true
        item.label.string = ""
        bus.trigger(name: "volume_change", info: "50")
        #expect(ran)
    }

    @Test func triggerPayloadCannotClobberContractVariables() {
        let bus = EventBus()
        let item = makeSubscribedItem(bus)
        bus.itemsProvider = { [item] }
        var environment: [String: String] = [:]
        bus.runItemScript = { _, env in environment = env }

        bus.trigger(name: "volume_change", info: "real-info",
                    extraEnvironment: ["NAME": "spoof", "SENDER": "spoof", "CUSTOM": "yes"])
        #expect(environment["NAME"] == "gated")
        #expect(environment["SENDER"] == "volume_change")
        #expect(environment["INFO"] == "real-info")
        #expect(environment["CUSTOM"] == "yes")
    }
}

@Suite struct PowerReductionTests {
    private func source(type: String, current: Int, max: Int, charging: Bool) -> [String: Any] {
        [
            kIOPSTypeKey: type,
            kIOPSCurrentCapacityKey: current,
            kIOPSMaxCapacityKey: max,
            kIOPSIsChargingKey: charging,
        ]
    }

    @Test func internalBatteryWinsOverUPS() {
        // UPS enumerated AFTER the internal battery must not mask it — and vice versa.
        let internalBattery = source(type: kIOPSInternalBatteryType, current: 42, max: 100, charging: true)
        let ups = source(type: kIOPSUPSType, current: 100, max: 100, charging: false)

        for order in [[internalBattery, ups], [ups, internalBattery]] {
            let snapshot = PowerProvider.reduce(descriptions: order, sourceType: "BATTERY")
            #expect(snapshot.percentage == 42)
            #expect(snapshot.isCharging == true)
        }
    }

    @Test func upsIsFallbackWhenNoInternalBattery() {
        let ups = source(type: kIOPSUPSType, current: 80, max: 100, charging: false)
        let snapshot = PowerProvider.reduce(descriptions: [ups], sourceType: "AC")
        #expect(snapshot.percentage == 80)
    }

    @Test func noSourcesYieldsNilPercentage() {
        let snapshot = PowerProvider.reduce(descriptions: [], sourceType: "AC")
        #expect(snapshot.percentage == nil)
    }
}

@MainActor
@Suite struct WidthSentinelTests {
    @Test func naturalLengthIgnoresFixedWidth() {
        let item = Item(name: "w", position: .left)
        item.label.string = "text"
        item.label.paddingLeft = 5
        item.label.paddingRight = 5
        item.customWidth = 300
        let measured = MeasuredContent(iconSize: .zero, labelSize: CGSize(width: 40, height: 14))
        #expect(Layout.naturalLength(item: item, measured: measured) == 50)
        #expect(Layout.contentLength(item: item, measured: measured) == 300)
    }

    @Test func directWidthDynamicStillSetsSentinel() {
        let item = Item(name: "w", position: .left)
        item.customWidth = 120
        let ctx = PropertyContext(scheduler: AnimationScheduler(), invalidate: {},
                                  measureNaturalWidth: { _ in 77 })
        _ = PropertySetter.set(item: item, property: "width", value: "dynamic", context: ctx)
        #expect(item.customWidth == -1)
    }

    @Test func animatedDynamicToFixedSeedsFromMeasuredWidth() {
        let item = Item(name: "w", position: .left)
        item.customWidth = -1
        var ctx = PropertyContext(scheduler: AnimationScheduler(), invalidate: {},
                                  measureNaturalWidth: { _ in 77 })
        ctx.animation = (curve: .linear, durationFrames: 30)
        _ = PropertySetter.set(item: item, property: "width", value: "200", context: ctx)
        // The animation starts from the measured width, so the item must not carry
        // the -1 sentinel anymore (the first frame would otherwise snap to ~0).
        #expect(item.customWidth == 77)
    }
}
