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
    /// A new alias item needs its capture loop armed.
    public var onAliasAdded: ((Item) -> Void)?
    public var onExit: (() -> Void)?
    public var onHotloadToggle: ((Bool) -> Void)?
    /// Forced provider re-queries keyed by event name (`--trigger volume_change` etc.).
    public var forcedQueries: [String: () -> Void] = [:]
    /// One-shot re-query of every provider for `--update` (the per-event closures
    /// may overlap; iterating them would double-fire).
    public var onForcedUpdate: (() -> Void)?
    /// Lua-first item dispatch (wired by the daemon; falls back to shell scripts).
    public var dispatchItem: ((Item, [String: String]) -> Void)?
    /// `--volume`: the daemon points this at AudioProvider (nil headless, so a
    /// test can never touch the real output device). Returns false when the
    /// device refused the write.
    public var onVolume: ((VolumeRequest) -> Bool)?

    /// What `--volume <token>` asks for. Absolute levels are the Windows port's
    /// grammar; the signed step form replaces the one thing themes still shelled
    /// `osascript` for — `set volume output volume ((output volume of (get
    /// volume settings)) + 4)` — without a read round trip through Lua.
    public enum VolumeRequest: Equatable {
        case absolute(Int)
        case step(Int)
    }

    /// Pure: `"50"` / `"50.6"` (rounded) → absolute 0...100; `"+4"` / `"-4"` →
    /// step. Anything else (out of range, non-numeric, empty) is nil.
    static func parseVolume(_ token: String) -> VolumeRequest? {
        if let sign = token.first, sign == "+" || sign == "-" {
            guard let delta = Int(token.dropFirst()) else { return nil }
            return .step(sign == "-" ? -delta : delta)
        }
        guard let level = Double(token), level.isFinite, level >= 0, level <= 100 else { return nil }
        return .absolute(Int(level.rounded()))
    }

    public init(barManager: BarManager, eventBus: EventBus,
                scriptRunner: ScriptRunner, scheduler: AnimationScheduler) {
        self.barManager = barManager
        self.eventBus = eventBus
        self.scriptRunner = scriptRunner
        self.scheduler = scheduler
    }

    public func handle(arguments: [String]) -> String {
        var output = ""
        var context = PropertyContext(
            scheduler: scheduler,
            invalidate: { [weak barManager] in barManager?.setNeedsRender() },
            measureNaturalWidth: { [weak barManager] item in
                barManager?.naturalWidth(of: item) ?? 0
            },
            measureTextNaturalWidth: { [weak barManager] item, icon in
                barManager?.naturalTextWidth(of: item, icon: icon) ?? 0
            })

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
                let targets = barManager.store.items(matching: name)
                guard !targets.isEmpty else {
                    emit("[!] no item matching \(name)")
                    continue
                }
                for token in batch.args.dropFirst() {
                    guard let (key, value) = CommandParser.keyValue(token) else {
                        emit("[!] expected key=value, got: \(token)")
                        continue
                    }
                    for item in targets {
                        emit(PropertySetter.set(item: item, property: key, value: value, context: context))
                    }
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
                for item in barManager.store.items
                where !item.script.isEmpty || item.hasLuaHandlers {
                    let environment = ["NAME": item.name, "SENDER": "forced", "INFO": ""]
                    if let dispatchItem {
                        dispatchItem(item, environment)
                    } else {
                        scriptRunner.run(script: item.script, environment: environment)
                    }
                }
                onForcedUpdate?()
                barManager.setNeedsRender()

            case "query":
                guard let target = batch.args.first else {
                    emit("[!] --query needs a target")
                    continue
                }
                emit(Serialize.query(target: target, manager: barManager, eventBus: eventBus))

            case "push":
                guard let name = batch.args.first,
                      let item = barManager.store.item(named: name),
                      let graph = item.graph
                else {
                    emit("[!] --push needs a graph item name")
                    continue
                }
                for token in batch.args.dropFirst() {
                    guard let value = Float(token) else {
                        emit("[!] invalid graph value: \(token)")
                        continue
                    }
                    graph.push(value)
                }
                barManager.setNeedsRender()

            case "remove":
                guard let name = batch.args.first else {
                    emit("[!] --remove needs an item name")
                    continue
                }
                let targets = barManager.store.items(matching: name)
                if targets.isEmpty {
                    emit("[!] no item matching \(name)")
                }
                for item in targets {
                    scheduler.cancel(prefix: "item.\(item.id).")
                    _ = barManager.store.remove(name: item.name)
                }
                barManager.setNeedsRender()

            case "move":
                guard batch.args.count == 3,
                      batch.args[1] == "before" || batch.args[1] == "after" else {
                    emit("[!] usage: --move <name> before|after <anchor>")
                    continue
                }
                if !barManager.store.move(name: batch.args[0], anchor: batch.args[2],
                                          before: batch.args[1] == "before") {
                    emit("[!] could not move \(batch.args[0])")
                }
                barManager.setNeedsRender()

            case "reorder":
                if !barManager.store.reorder(names: batch.args) {
                    emit("[!] could not reorder (unknown names?)")
                }
                barManager.setNeedsRender()

            case "rename":
                guard batch.args.count == 2 else {
                    emit("[!] usage: --rename <old> <new>")
                    continue
                }
                if !barManager.store.rename(from: batch.args[0], to: batch.args[1]) {
                    emit("[!] could not rename \(batch.args[0])")
                }

            case "clone":
                guard batch.args.count >= 2 else {
                    emit("[!] usage: --clone <new-name> <source> [before|after]")
                    continue
                }
                if barManager.store.clone(source: batch.args[1], as: batch.args[0]) == nil {
                    emit("[!] could not clone \(batch.args[1])")
                } else {
                    if batch.args.count == 3 {
                        _ = barManager.store.move(name: batch.args[0], anchor: batch.args[1],
                                                  before: batch.args[2] == "before")
                    }
                    barManager.setNeedsRender()
                }

            case "reload":
                onReload?(batch.args.first)

            case "hotload":
                guard let flag = PropertySetter.parseBool(batch.args.first ?? "") else {
                    emit("[!] usage: --hotload <on|off>")
                    continue
                }
                onHotloadToggle?(flag)

            case "volume":
                // ybar extension, mirrored from the Windows port: the daemon
                // already holds the output device, so a slider drag is one
                // call instead of an osascript spawn. The port's optional
                // second token routes to an app's audio session; macOS has
                // no per-app volume API, so it is refused by name.
                guard batch.args.count == 1 || batch.args.count == 2 else {
                    emit("[!] usage: --volume <0-100|+N|-N>")
                    continue
                }
                if batch.args.count == 2 {
                    emit("[!] per-app volume is not available on macOS")
                    continue
                }
                guard let request = CommandHandler.parseVolume(batch.args[0]) else {
                    emit("[!] invalid volume: \(batch.args[0])")
                    continue
                }
                guard let onVolume else {
                    emit("[!] volume control is not available")
                    continue
                }
                if !onVolume(request) {
                    emit("[!] the output device refused the volume change")
                }

            case "exit":
                onExit?()

            default:
                emit("[!] unknown domain: --\(batch.domain)")
            }
        }
        return output
    }

    private func handleAdd(args: [String]) -> String? {
        // --add alias "<Owner>[,Window Title]" <position> [scale]
        if args.first == "alias" {
            guard args.count >= 3, let position = ItemPosition.parse(args[2]) else {
                return "[!] usage: --add alias \"Owner[,Window]\" <position>"
            }
            guard let item = barManager.store.add(name: args[1], position: position) else {
                return "[!] item exists: \(args[1])"
            }
            item.kind = .alias
            item.alias = AliasState(spec: args[1])
            onAliasAdded?(item)
            barManager.setNeedsRender()
            return nil
        }
        guard let kind = args.first else { return "[!] --add needs a type" }
        switch kind {
        case "item":
            guard args.count >= 3 else { return "[!] usage: --add item <name> <position>" }
            guard let item = addItem(name: args[1], positionToken: args[2]) else {
                return "[!] invalid position or duplicate name: \(args[1]) \(args[2])"
            }
            _ = item
            barManager.setNeedsRender()
            return nil

        case "graph":
            guard args.count >= 4, let width = Int(args[3]), width > 0, width <= 8192 else {
                return "[!] usage: --add graph <name> <position> <width> (1...8192)"
            }
            guard let item = addItem(name: args[1], positionToken: args[2]) else {
                return "[!] invalid position or duplicate name: \(args[1]) \(args[2])"
            }
            item.kind = .graph
            item.graph = GraphState(capacity: width)
            barManager.setNeedsRender()
            return nil

        case "slider":
            guard args.count >= 4, let width = Float(args[3]), width.isFinite, width > 0 else {
                return "[!] usage: --add slider <name> <position> <width>"
            }
            guard let item = addItem(name: args[1], positionToken: args[2]) else {
                return "[!] invalid position or duplicate name: \(args[1]) \(args[2])"
            }
            item.kind = .slider
            item.slider = SliderState(width: width)
            barManager.setNeedsRender()
            return nil

        case "bracket":
            guard args.count >= 3 else { return "[!] usage: --add bracket <name> <member>..." }
            let members = Array(args.dropFirst(2))
            let missing = members.filter {
                ItemStore.regexPattern(from: $0) == nil && barManager.store.item(named: $0) == nil
            }
            guard missing.isEmpty else { return "[!] unknown bracket members: \(missing.joined(separator: ", "))" }
            guard let item = barManager.store.add(name: args[1], position: .left) else {
                return "[!] item \(args[1]) already exists"
            }
            item.kind = .bracket
            item.members = members
            item.background.drawing = true
            barManager.setNeedsRender()
            return nil

        case "event":
            guard args.count >= 2 else { return "[!] usage: --add event <name> [notification]" }
            return eventBus.addEvent(name: args[1], notificationName: args.count >= 3 ? args[2] : nil)

        default:
            return "[!] unknown --add type: \(kind) (supported: item, graph, slider, bracket, event)"
        }
    }

    /// Resolve a position token, including `popup.<host>` placements.
    private func addItem(name: String, positionToken: String) -> Item? {
        if positionToken.hasPrefix("popup.") {
            let host = String(positionToken.dropFirst("popup.".count))
            guard barManager.store.item(named: host) != nil,
                  let item = barManager.store.add(name: name, position: .popup)
            else { return nil }
            item.popupHost = host
            return item
        }
        guard let position = ItemPosition.parse(positionToken) else { return nil }
        return barManager.store.add(name: name, position: position)
    }
}
