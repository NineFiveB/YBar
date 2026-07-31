import Foundation

/// Named events with per-item subscription bitmasks (u64, sketchybar-compatible).
/// Built-ins occupy the low bits; custom events (`--add event`) append, optionally
/// bound to an NSDistributedNotificationCenter name whose userInfo is JSON-serialized
/// into $INFO — the cheap hook that makes Spotify-style integrations work.
@MainActor
public final class EventBus {
    public struct EventDefinition {
        public let name: String
        public let bit: UInt64
        public let notificationName: String?
    }

    public static let builtinEvents: [String] = [
        "front_app_switched", "space_change", "display_change",
        "system_woke", "system_will_sleep",
        "mouse.entered", "mouse.exited", "mouse.clicked", "mouse.scrolled",
        "volume_change", "power_source_change", "battery_change", "wifi_change",
        "system_stats", "mouse.exited.global",
    ]

    public private(set) var definitions: [EventDefinition] = []
    private var observers: [String: NSObjectProtocol] = [:]

    /// Wired by the daemon: run an item's script with the given environment.
    public var runItemScript: ((Item, [String: String]) -> Void)?
    /// Items provider (the store lives on BarManager).
    public var itemsProvider: (() -> [Item])?
    /// Lazy provider arming: called the first time any item subscribes to an event.
    public var onFirstSubscription: ((String) -> Void)?

    private var armedEvents: Set<String> = []

    public init() {
        for name in EventBus.builtinEvents {
            appendDefinition(name: name, notificationName: nil)
        }
    }

    public func reset() {
        for observer in observers.values {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        definitions.removeAll()
        armedEvents.removeAll()
        for name in EventBus.builtinEvents {
            appendDefinition(name: name, notificationName: nil)
        }
    }

    public func bit(for name: String) -> UInt64? {
        definitions.first { $0.name == name }?.bit
    }

    /// Register a custom event; no-op if it already exists. 64-event cap.
    @discardableResult
    public func addEvent(name: String, notificationName: String? = nil) -> String? {
        if bit(for: name) != nil { return nil }
        guard definitions.count < 64 else { return "[!] event limit reached (64)" }
        appendDefinition(name: name, notificationName: notificationName)
        if let notificationName {
            observeDistributedNotification(named: notificationName, eventName: name)
        }
        return nil
    }

    public func subscribe(item: Item, eventName: String) -> String? {
        guard let bit = bit(for: eventName) else {
            return "[!] unknown event: \(eventName)"
        }
        item.updateMask |= bit
        if !armedEvents.contains(eventName) {
            armedEvents.insert(eventName)
            onFirstSubscription?(eventName)
        }
        return nil
    }

    /// Fire an event to all subscribed items' scripts. The `updates` policy gates
    /// event-driven runs exactly like routine ones (sketchybar contract); mouse
    /// events and `--update` intentionally bypass it via their own paths.
    public func trigger(name: String, info: String = "", extraEnvironment: [String: String] = [:]) {
        guard let bit = bit(for: name), let items = itemsProvider?() else { return }
        for item in items where item.updateMask & bit != 0
            && (!item.script.isEmpty || item.hasLuaHandlers) {
            if item.updatePolicy == .off { continue }
            // when_shown gates on drawing (sketchybar semantics), NOT on content:
            // an empty item must still receive the update that populates it.
            if item.updatePolicy == .whenShown, !item.drawing { continue }
            // Contract variables are applied last: a `--trigger e NAME=x` payload
            // must never clobber the receiving item's identity.
            var environment = extraEnvironment
            environment["NAME"] = item.name
            environment["SENDER"] = name
            environment["INFO"] = info
            runItemScript?(item, environment)
        }
    }

    private func appendDefinition(name: String, notificationName: String?) {
        let bit: UInt64 = 1 << UInt64(definitions.count)
        definitions.append(EventDefinition(name: name, bit: bit, notificationName: notificationName))
    }

    private func observeDistributedNotification(named notificationName: String, eventName: String) {
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(notificationName),
            object: nil,
            queue: .main
        ) { notification in
            let info: String
            if let userInfo = notification.userInfo,
               let data = try? JSONSerialization.data(withJSONObject: userInfo, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                info = json
            } else {
                info = ""
            }
            MainActor.assumeIsolated {
                // Re-resolve through the default center's main-queue delivery.
                NotificationBridge.shared.deliver(eventName: eventName, info: info)
            }
        }
        observers[notificationName] = observer
    }
}

/// Small indirection so distributed-notification closures don't retain the bus.
@MainActor
final class NotificationBridge {
    static let shared = NotificationBridge()
    weak var bus: EventBus?

    func deliver(eventName: String, info: String) {
        bus?.trigger(name: eventName, info: info)
    }
}
