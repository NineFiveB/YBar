import Foundation

/// Executes parsed command batches against the live object model.
/// `--animate` is a message-scoped modifier: it applies to every subsequent
/// `--set`/`--bar` in the same message and resets when the message ends
/// (sketchybar semantics).
@MainActor
public final class CommandHandler {
    let barManager: BarManager
    let eventBus: EventBus
    let scriptRunner: ScriptRunner
    let scheduler: AnimationScheduler

    /// Daemon control hooks.
    public var onReload: ((String?) -> Void)?
    public var onExit: (() -> Void)?
    public var onHotloadToggle: ((Bool) -> Void)?
    /// Forced provider re-queries keyed by event name (`--trigger volume_change` etc.).
    public var forcedQueries: [String: () -> Void] = [:]

    public init(barManager: BarManager, eventBus: EventBus,
                scriptRunner: ScriptRunner, scheduler: AnimationScheduler) {
        self.barManager = barManager
        self.eventBus = eventBus
        self.scriptRunner = scriptRunner
        self.scheduler = scheduler
    }

    public func handle(arguments: [String]) -> String {
        var output = ""
        var context = PropertyContext(scheduler: scheduler) { [weak barManager] in
            barManager?.setNeedsRender()
        }

        func emit(_ line: String?) {
            guard let line, !line.isEmpty else { return }
            if !output.isEmpty { output += "\n" }
            output += line
        }

        for batch in CommandParser.batches(from: arguments) {
            switch batch.domain {
            case "ping":
                emit("pong")

            case "bar":
                for token in batch.args {
                    guard let (key, value) = CommandParser.keyValue(token) else {
                        emit("[!] expected key=value, got: \(token)")
                        continue
                    }
                    emit(BarPropertySetter.set(manager: barManager, property: key,
                                               value: value, context: context))
                }

            case "default":
                if batch.args == ["reset"] {
                    barManager.store.resetDefaults()
                    continue
                }
                let defaults = barManager.store.defaults
                var defaultsContext = context
                defaultsContext.animation = nil
                for token in batch.args {
                    guard let (key, value) = CommandParser.keyValue(token) else {
                        emit("[!] expected key=value, got: \(token)")
                        continue
                    }
                    emit(PropertySetter.set(item: defaults, property: key,
                                            value: value, context: defaultsContext))
                }

            case "add":
                emit(handleAdd(args: batch.args))

            case "set":
                guard let name = batch.args.first else {
                    emit("[!] --set needs an item name")
                    continue
                }
                guard let item = barManager.store.item(named: name) else {
                    emit("[!] no item named \(name)")
                    continue
                }
                for token in batch.args.dropFirst() {
                    guard let (key, value) = CommandParser.keyValue(token) else {
                        emit("[!] expected key=value, got: \(token)")
                        continue
                    }
                    emit(PropertySetter.set(item: item, property: key, value: value, context: context))
                }

            case "subscribe":
                guard let name = batch.args.first else {
                    emit("[!] --subscribe needs an item name")
                    continue
                }
                guard let item = barManager.store.item(named: name) else {
                    emit("[!] no item named \(name)")
                    continue
                }
                for eventName in batch.args.dropFirst() {
                    emit(eventBus.subscribe(item: item, eventName: eventName))
                }

            case "trigger":
                guard let eventName = batch.args.first else {
                    emit("[!] --trigger needs an event name")
                    continue
                }
                var extra: [String: String] = [:]
                for token in batch.args.dropFirst() {
                    if let (key, value) = CommandParser.keyValue(token) {
                        extra[key] = value
                    }
                }
                if let forced = forcedQueries[eventName] {
                    forced()
                } else {
                    eventBus.trigger(name: eventName, info: extra["INFO"] ?? "",
                                     extraEnvironment: extra)
                }

            case "animate":
                guard batch.args.count >= 2, let frames = Int(batch.args[1]), frames >= 0 else {
                    emit("[!] usage: --animate <curve> <duration-frames>")
                    continue
                }
                context.animation = (AnimationCurve.parse(batch.args[0]), frames)

            case "update":
                for item in barManager.store.items where !item.script.isEmpty {
                    scriptRunner.run(script: item.script, environment: [
                        "NAME": item.name, "SENDER": "forced", "INFO": "",
                    ])
                }
                for forced in forcedQueries.values { forced() }
                barManager.setNeedsRender()

            case "query":
                guard let target = batch.args.first else {
                    emit("[!] --query needs a target")
                    continue
                }
                emit(Serialize.query(target: target, manager: barManager, eventBus: eventBus))

            case "remove":
                guard let name = batch.args.first else {
                    emit("[!] --remove needs an item name")
                    continue
                }
                if !barManager.store.remove(name: name) {
                    emit("[!] no item named \(name)")
                }
                barManager.setNeedsRender()

            case "reload":
                onReload?(batch.args.first)

            case "hotload":
                guard let flag = PropertySetter.parseBool(batch.args.first ?? "") else {
                    emit("[!] usage: --hotload <on|off>")
                    continue
                }
                onHotloadToggle?(flag)

            case "exit":
                onExit?()

            default:
                emit("[!] unknown domain: --\(batch.domain)")
            }
        }
        return output
    }

    private func handleAdd(args: [String]) -> String? {
        guard let kind = args.first else { return "[!] --add needs a type" }
        switch kind {
        case "item":
            guard args.count >= 3 else { return "[!] usage: --add item <name> <position>" }
            guard let position = ItemPosition.parse(args[2]) else {
                return "[!] invalid position: \(args[2])"
            }
            guard barManager.store.add(name: args[1], position: position) != nil else {
                return "[!] item \(args[1]) already exists"
            }
            barManager.setNeedsRender()
            return nil
        case "event":
            guard args.count >= 2 else { return "[!] usage: --add event <name> [notification]" }
            return eventBus.addEvent(name: args[1], notificationName: args.count >= 3 ? args[2] : nil)
        default:
            return "[!] unknown --add type: \(kind) (v1 supports: item, event)"
        }
    }
}
