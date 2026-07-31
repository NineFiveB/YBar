import AppKit
import CLua

// Lua C-API macros/constants don't import into Swift; the ones we need,
// spelled out against the vendored 5.4 configuration.
// LUA_REGISTRYINDEX = -LUAI_MAXSTACK - 1000.
private let registryIndex: Int32 = -1_001_000
private let luaOK: Int32 = 0
private let luaTypeNil: Int32 = 0
private let luaTypeNumber: Int32 = 3
private let luaTypeString: Int32 = 4
private let luaTypeTable: Int32 = 5
private let luaTypeFunction: Int32 = 6
private let luaRefNil: Int32 = -1

private func pop(_ state: OpaquePointer?, _ count: Int32) {
    lua_settop(state, -count - 1)
}

private func toString(_ state: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = lua_tolstring(state, index, nil) else { return nil }
    return String(cString: cString)
}

/// Non-raising argument accessor. The luaL_check* family raises Lua errors via
/// longjmp, which would unwind straight through Swift frames (skipping ARC
/// releases — formally UB). Trampolines therefore never call raising APIs:
/// bad arguments surface as error strings/stderr instead.
private func argString(_ state: OpaquePointer?, _ index: Int32) -> String? {
    let type = lua_type(state, index)
    guard type == luaTypeString || type == luaTypeNumber else { return nil }
    return toString(state, index)
}

private func optString(_ state: OpaquePointer?, _ index: Int32) -> String? {
    guard lua_type(state, index) > 0 else { return nil } // LUA_TNIL = 0, none = -1
    return toString(state, index)
}

/// The embedded Lua config runtime — YbarLua. Configs run inside the daemon:
/// zero IPC, zero process spawns; event/click/routine callbacks are direct Lua
/// function calls. The C bridge is deliberately tiny (`__ybar_raw`, single
/// key/value calls + callback refs); ergonomics (nested-table flattening, item
/// handles, animate wrapper) live in a Lua prelude.
@MainActor
public final class LuaRuntime {
    static var current: LuaRuntime?

    private var state: OpaquePointer?
    unowned let barManager: BarManager
    unowned let eventBus: EventBus
    unowned let scheduler: AnimationScheduler

    /// (item id → event name → Lua registry ref)
    private var subscriptions: [Int: [String: Int32]] = [:]
    /// Active `ybar.animate` context for property sets.
    var animationContext: (curve: AnimationCurve, durationFrames: Int)?
    /// Registry refs are small integers scoped to ONE lua_State; a completion
    /// crossing a reload would index the NEW state's registry and invoke an
    /// unrelated callback. Bumped on every state teardown; async completions
    /// carry the generation they were minted in and bail on mismatch.
    private var stateGeneration: UInt64 = 0

    public init(barManager: BarManager, eventBus: EventBus, scheduler: AnimationScheduler) {
        self.barManager = barManager
        self.eventBus = eventBus
        self.scheduler = scheduler
        LuaRuntime.current = self
    }

    public func shutdown() {
        shutdownStateOnly()
        if LuaRuntime.current === self { LuaRuntime.current = nil }
    }

    // MARK: - Config execution

    /// Run a Lua config. Returns an error string or nil on success.
    @discardableResult
    public func runConfig(at url: URL) -> String? {
        shutdownStateOnly()
        guard let state = luaL_newstate() else { return "[!] lua: out of memory" }
        self.state = state
        luaL_openlibs(state)
        registerRawModule(state)
        if let error = run(code: LuaRuntime.prelude, name: "=ybar-prelude") {
            return error
        }
        // require("colors") etc. resolve against the config directory.
        let directory = url.deletingLastPathComponent().path
        _ = run(code: "package.path = [[\(directory)/?.lua;\(directory)/?/init.lua;]] .. package.path",
                name: "=ybar-package-path")
        if luaL_loadfilex(state, url.path, nil) != luaOK {
            let error = toString(state, -1) ?? "unknown load error"
            pop(state, 1)
            return "[!] lua: \(error)"
        }
        if lua_pcallk(state, 0, 0, 0, 0, nil) != luaOK {
            let error = toString(state, -1) ?? "unknown runtime error"
            pop(state, 1)
            return "[!] lua: \(error)"
        }
        return nil
    }

    private func shutdownStateOnly() {
        if let state { lua_close(state) }
        state = nil
        subscriptions.removeAll()
        animationContext = nil
        stateGeneration += 1
    }

    private func run(code: String, name: String) -> String? {
        guard let state else { return "[!] lua: no state" }
        if luaL_loadbufferx(state, code, code.utf8.count, name, nil) != luaOK
            || lua_pcallk(state, 0, 0, 0, 0, nil) != luaOK {
            let error = toString(state, -1) ?? "unknown error"
            pop(state, 1)
            return "[!] lua: \(error)"
        }
        return nil
    }

    // MARK: - Event dispatch (Lua-first)

    /// Deliver an event to a registered Lua callback. Returns false when this
    /// item/event pair has no Lua handler (caller falls back to shell scripts).
    public func handleEvent(item: Item, environment: [String: String]) -> Bool {
        guard state != nil else { return false }
        let sender = environment["SENDER"] ?? ""
        var ref = subscriptions[item.id]?[sender]
        if ref == nil, sender == "forced" {
            // --update reaches routine handlers, like shell scripts see SENDER=forced.
            ref = subscriptions[item.id]?["routine"]
        }
        guard let ref else { return false }
        call(ref: ref, environment: environment)
        return true
    }

    public func hasHandlers(for item: Item) -> Bool {
        !(subscriptions[item.id]?.isEmpty ?? true)
    }

    private func call(ref: Int32, environment: [String: String]) {
        guard let state else { return }
        lua_rawgeti(state, registryIndex, lua_Integer(ref))
        lua_createtable(state, 0, Int32(environment.count))
        for (key, value) in environment {
            lua_pushstring(state, value)
            lua_setfield(state, -2, key)
        }
        if lua_pcallk(state, 1, 0, 0, 0, nil) != luaOK {
            let error = toString(state, -1) ?? "unknown error"
            pop(state, 1)
            FileHandle.standardError.write(Data("[ybar] lua callback error: \(error)\n".utf8))
        }
    }

    /// Async exec completion — called back on main with captured output.
    /// The generation gate drops completions that outlived their lua_State.
    func completeExec(ref: Int32, generation: UInt64, output: String, exitCode: Int32) {
        guard generation == stateGeneration, let state else { return }
        lua_rawgeti(state, registryIndex, lua_Integer(ref))
        luaL_unref(state, registryIndex, ref)
        lua_pushstring(state, output)
        lua_pushinteger(state, lua_Integer(exitCode))
        if lua_pcallk(state, 2, 0, 0, 0, nil) != luaOK {
            let error = toString(state, -1) ?? "unknown error"
            pop(state, 1)
            FileHandle.standardError.write(Data("[ybar] lua exec callback error: \(error)\n".utf8))
        }
    }

    // MARK: - Property context

    fileprivate func propertyContext() -> PropertyContext {
        PropertyContext(
            scheduler: scheduler,
            animation: animationContext,
            invalidate: { [weak barManager] in barManager?.setNeedsRender() },
            measureNaturalWidth: { [weak barManager] item in
                barManager?.naturalWidth(of: item) ?? 0
            },
            measureTextNaturalWidth: { [weak barManager] item, icon in
                barManager?.naturalTextWidth(of: item, icon: icon) ?? 0
            })
    }

    fileprivate func subscribe(itemName: String, event: String, ref: Int32) -> String? {
        guard let item = barManager.store.item(named: itemName) else {
            return "[!] no item named \(itemName)"
        }
        // "routine"/"forced" are dispatch pseudo-events (timer ticks and
        // --update); real events register with the bus.
        if event != "routine" && event != "forced" {
            if let error = eventBus.subscribe(item: item, eventName: event) {
                return error
            }
        }
        if let previous = subscriptions[item.id]?[event], let state {
            luaL_unref(state, registryIndex, previous)
        }
        subscriptions[item.id, default: [:]][event] = ref
        item.hasLuaHandlers = true
        return nil
    }

    // MARK: - Raw module registration

    private func registerRawModule(_ state: OpaquePointer) {
        lua_createtable(state, 0, 12)

        func register(_ name: String, _ function: lua_CFunction) {
            lua_pushcclosure(state, function, 0)
            lua_setfield(state, -2, name)
        }

        register("bar") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let key = argString(L, 1), let value = argString(L, 2) else {
                    lua_pushstring(L, "[!] bar(key, value) expects strings")
                    return 1
                }
                pushOptionalError(L, BarPropertySetter.set(
                    manager: runtime.barManager, property: key, value: value,
                    context: runtime.propertyContext()))
                return 1
            }
        }
        register("default") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let key = argString(L, 1), let value = argString(L, 2) else {
                    lua_pushstring(L, "[!] default(key, value) expects strings")
                    return 1
                }
                var context = runtime.propertyContext()
                context.animation = nil
                pushOptionalError(L, PropertySetter.set(
                    item: runtime.barManager.store.defaults, property: key,
                    value: value, context: context))
                return 1
            }
        }
        register("add") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let kind = argString(L, 1), let name = argString(L, 2),
                      let position = argString(L, 3) else {
                    lua_pushboolean(L, 0)
                    FileHandle.standardError.write(
                        Data("[ybar] lua: add(kind, name, position) expects strings\n".utf8))
                    return 1
                }
                let width = lua_type(L, 4) == luaTypeNumber ? Float(lua_tonumberx(L, 4, nil)) : nil
                let error = runtime.addItem(kind: kind, name: name, position: position, width: width)
                lua_pushboolean(L, error == nil ? 1 : 0)
                if let error {
                    FileHandle.standardError.write(Data("[ybar] lua: \(error)\n".utf8))
                }
                return 1
            }
        }
        register("set") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let name = argString(L, 1), let key = argString(L, 2),
                      let value = argString(L, 3) else {
                    lua_pushstring(L, "[!] set(name, key, value) expects strings")
                    return 1
                }
                let targets = runtime.barManager.store.items(matching: name)
                guard !targets.isEmpty else {
                    lua_pushstring(L, "[!] no item matching \(name)")
                    return 1
                }
                var firstError: String?
                for item in targets {
                    let error = PropertySetter.set(
                        item: item, property: key, value: value,
                        context: runtime.propertyContext())
                    if firstError == nil { firstError = error }
                }
                pushOptionalError(L, firstError)
                return 1
            }
        }
        register("subscribe") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let name = argString(L, 1), let event = argString(L, 2),
                      lua_type(L, 3) == luaTypeFunction else {
                    lua_pushstring(L, "[!] subscribe(name, event, fn) expects (string, string, function)")
                    return 1
                }
                lua_pushvalue(L, 3)
                let ref = Int32(luaL_ref(L, registryIndex))
                pushOptionalError(L, runtime.subscribe(itemName: name, event: event, ref: ref))
                return 1
            }
        }
        register("trigger") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let event = argString(L, 1) else {
                    FileHandle.standardError.write(Data("[ybar] lua: trigger(event) expects a string\n".utf8))
                    return 0
                }
                var extra: [String: String] = [:]
                if lua_type(L, 2) == luaTypeTable {
                    lua_pushnil(L)
                    while lua_next(L, 2) != 0 {
                        // NEVER lua_tolstring the key slot in place: converting a
                        // number key corrupts lua_next traversal ("invalid key to
                        // 'next'"). Stringify a copy instead.
                        lua_pushvalue(L, -2)
                        let key = argString(L, -1)
                        pop(L, 1)
                        let value = optString(L, -1)
                        if let key, let value {
                            extra[key] = value
                        }
                        pop(L, 1)
                    }
                }
                runtime.eventBus.trigger(name: event, info: extra["INFO"] ?? "",
                                         extraEnvironment: extra)
                return 0
            }
        }
        register("push") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let name = argString(L, 1), lua_type(L, 2) == luaTypeTable else {
                    FileHandle.standardError.write(Data("[ybar] lua: push(name, values) expects (string, table)\n".utf8))
                    return 0
                }
                guard let graph = runtime.barManager.store.item(named: name)?.graph else { return 0 }
                let count = lua_rawlen(L, 2)
                guard count > 0 else { return 0 }
                for index in 1...count {
                    lua_rawgeti(L, 2, lua_Integer(index))
                    if lua_type(L, -1) == luaTypeNumber {
                        graph.push(Float(lua_tonumberx(L, -1, nil)))
                    }
                    pop(L, 1)
                }
                runtime.barManager.setNeedsRender()
                return 0
            }
        }
        register("animate_begin") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let curve = argString(L, 1), lua_type(L, 2) == luaTypeNumber else {
                    FileHandle.standardError.write(Data("[ybar] lua: animate(curve, frames, fn) expects (string, number)\n".utf8))
                    return 0
                }
                let frames = Int(lua_tointegerx(L, 2, nil))
                runtime.animationContext = (AnimationCurve.parse(curve), frames)
                return 0
            }
        }
        register("animate_end") { _ in
            MainActor.assumeIsolated {
                LuaRuntime.current?.animationContext = nil
                return 0
            }
        }
        register("exec") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let command = argString(L, 1) else {
                    FileHandle.standardError.write(Data("[ybar] lua: exec(cmd, fn?) expects a string\n".utf8))
                    return 0
                }
                var ref: Int32 = luaRefNil
                if lua_type(L, 2) == luaTypeFunction {
                    lua_pushvalue(L, 2)
                    ref = Int32(luaL_ref(L, registryIndex))
                }
                runtime.execAsync(command: command, ref: ref)
                return 0
            }
        }
        register("delay") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard lua_type(L, 1) == luaTypeNumber, lua_type(L, 2) == luaTypeFunction else {
                    FileHandle.standardError.write(
                        Data("[ybar] lua: delay(seconds, fn) expects (number, function)\n".utf8))
                    return 0
                }
                let seconds = lua_tonumberx(L, 1, nil)
                lua_pushvalue(L, 2)
                let ref = Int32(luaL_ref(L, registryIndex))
                runtime.scheduleDelay(seconds: seconds, ref: ref)
                return 0
            }
        }
        register("update") { _ in
            MainActor.assumeIsolated {
                LuaRuntime.current?.dispatchForcedToAllHandlers()
                return 0
            }
        }
        register("query_item") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current, let name = argString(L, 1),
                      let item = runtime.barManager.store.item(named: name)
                else {
                    lua_pushnil(L)
                    return 1
                }
                let dictionary = Serialize.itemDictionary(
                    item, boundingRects: runtime.barManager.boundingRects(for: item))
                LuaRuntime.push(dictionary, to: L)
                return 1
            }
        }
        register("add_event") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let name = argString(L, 1) else {
                    lua_pushstring(L, "[!] add_event(name) expects a string")
                    return 1
                }
                let notification = optString(L, 2)
                pushOptionalError(L, runtime.eventBus.addEvent(
                    name: name, notificationName: notification))
                return 1
            }
        }
        register("query") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let target = argString(L, 1) else {
                    lua_pushstring(L, "[!] query(target) expects a string")
                    return 1
                }
                lua_pushstring(L, Serialize.query(
                    target: target, manager: runtime.barManager, eventBus: runtime.eventBus))
                return 1
            }
        }
        register("remove") { L in
            MainActor.assumeIsolated {
                guard let runtime = LuaRuntime.current else { return 0 }
                guard let name = argString(L, 1) else { return 0 }
                for item in runtime.barManager.store.items(matching: name) {
                    _ = runtime.barManager.store.remove(name: item.name)
                }
                runtime.barManager.setNeedsRender()
                return 0
            }
        }

        lua_setglobal(state, "__ybar_raw")
    }

    private func addItem(kind: String, name: String, position: String, width: Float?) -> String? {
        let store = barManager.store

        func resolve(_ token: String) -> Item? {
            if token.hasPrefix("popup.") {
                let host = String(token.dropFirst("popup.".count))
                guard store.item(named: host) != nil,
                      let item = store.add(name: name, position: .popup) else { return nil }
                item.popupHost = host
                return item
            }
            guard let parsed = ItemPosition.parse(token) else { return nil }
            return store.add(name: name, position: parsed)
        }

        switch kind {
        case "item":
            guard resolve(position) != nil else { return "[!] add failed: \(name) \(position)" }
        case "graph":
            guard let item = resolve(position) else { return "[!] add failed: \(name) \(position)" }
            item.kind = .graph
            item.graph = GraphState(capacity: Int(width ?? 60))
        case "slider":
            guard let item = resolve(position) else { return "[!] add failed: \(name) \(position)" }
            item.kind = .slider
            item.slider = SliderState(width: width ?? 100)
        case "bracket":
            // position carries comma-separated members for brackets.
            let members = position.split(separator: ",").map(String.init)
            let missing = members.filter {
                !$0.hasPrefix("/") && store.item(named: $0) == nil
            }
            guard missing.isEmpty else { return "[!] unknown bracket members: \(missing.joined(separator: ", "))" }
            guard let item = store.add(name: name, position: .left) else {
                return "[!] item \(name) already exists"
            }
            item.kind = .bracket
            item.members = members
            item.background.drawing = true
        default:
            return "[!] unknown kind: \(kind)"
        }
        barManager.setNeedsRender()
        return nil
    }

    private func execAsync(command: String, ref: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["sh", "-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = ScriptRunner.augmentedPATH(environment["PATH"])
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.standardError
        let generation = stateGeneration

        do {
            try process.run()
        } catch {
            FileHandle.standardError.write(Data("[ybar] lua exec failed: \(error)\n".utf8))
            if ref != luaRefNil, let state {
                luaL_unref(state, registryIndex, ref)
            }
            return
        }

        // Same watchdog as shell plugin scripts: a hung child must not linger.
        let box = ProcessBox(process: process)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) {
            box.terminateIfRunning()
        }

        // Drain the pipe CONCURRENTLY with the child — reading only after
        // termination deadlocks any child writing more than the ~64KB pipe
        // buffer (it blocks in write(2) and never exits).
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            var output = String(decoding: data, as: UTF8.self)
            if output.hasSuffix("\n") { output.removeLast() }
            let code = process.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard ref != luaRefNil else { return }
                    LuaRuntime.current?.completeExec(
                        ref: ref, generation: generation, output: output, exitCode: code)
                }
            }
        }
    }

    /// SENDER=forced to every item's Lua handlers, one call per distinct
    /// handler (`ybar.update()` — the boot-population idiom sketchybar's
    /// --update provides for shell configs).
    func dispatchForcedToAllHandlers() {
        for item in barManager.store.items {
            guard let handlers = subscriptions[item.id], !handlers.isEmpty else { continue }
            var calledRefs = Set<Int32>()
            for (_, ref) in handlers where !calledRefs.contains(ref) {
                calledRefs.insert(ref)
                call(ref: ref, environment: [
                    "NAME": item.name, "SENDER": "forced", "INFO": "",
                ])
            }
        }
        barManager.setNeedsRender()
    }

    /// Generation-guarded delayed callback (`ybar.delay`).
    func scheduleDelay(seconds: Double, ref: Int32) {
        let generation = stateGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.stateGeneration, let state = self.state else { return }
                lua_rawgeti(state, registryIndex, lua_Integer(ref))
                luaL_unref(state, registryIndex, ref)
                if lua_pcallk(state, 0, 0, 0, 0, nil) != luaOK {
                    let error = toString(state, -1) ?? "unknown error"
                    pop(state, 1)
                    FileHandle.standardError.write(Data("[ybar] lua delay error: \(error)\n".utf8))
                }
            }
        }
    }

    /// Recursively push a Serialize dictionary as a Lua table.
    static func push(_ value: Any, to L: OpaquePointer?) {
        switch value {
        case let bool as Bool:
            lua_pushboolean(L, bool ? 1 : 0)
        case let string as String:
            lua_pushstring(L, string)
        case let int as Int:
            lua_pushinteger(L, lua_Integer(int))
        case let uint32 as UInt32:
            lua_pushinteger(L, lua_Integer(uint32))
        case let uint64 as UInt64:
            lua_pushinteger(L, lua_Integer(truncatingIfNeeded: uint64))
        case let float as Float:
            lua_pushnumber(L, Double(float))
        case let double as Double:
            lua_pushnumber(L, double)
        case let cgFloat as CGFloat:
            lua_pushnumber(L, Double(cgFloat))
        case let array as [Any]:
            lua_createtable(L, Int32(array.count), 0)
            for (index, element) in array.enumerated() {
                LuaRuntime.push(element, to: L)
                lua_rawseti(L, -2, lua_Integer(index + 1))
            }
        case let dictionary as [String: Any]:
            lua_createtable(L, 0, Int32(dictionary.count))
            for (key, element) in dictionary {
                LuaRuntime.push(element, to: L)
                lua_setfield(L, -2, key)
            }
        default:
            lua_pushnil(L)
        }
    }

    // MARK: - Prelude (the user-facing `ybar` API, in Lua)

    static let prelude = """
    local raw = __ybar_raw
    __ybar_raw = nil

    local function flatten(prefix, t, out)
      for k, v in pairs(t) do
        local key = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
        if type(v) == "table" then
          flatten(key, v, out)
        else
          out[key] = v
        end
      end
    end

    local function valstr(v)
      if type(v) == "boolean" then return v and "on" or "off" end
      if type(v) == "number" then
        -- 60/2 is a FLOAT in Lua 5.4 and tostring gives "30.0", which
        -- integer-parsed properties (update_freq, max_chars...) reject.
        local i = math.tointeger(v)
        if i then return tostring(i) end
      end
      return tostring(v)
    end

    local function apply(fn, first, t)
      local out = {}
      flatten("", t, out)
      for k, v in pairs(out) do
        -- NOT `a and fn(...) or fn(...)`: a successful call returns nil and
        -- the or-branch would re-call with the wrong arity.
        local err
        if first then
          err = fn(first, k, valstr(v))
        else
          err = fn(k, valstr(v))
        end
        if err then print(err) end
      end
    end

    ybar = {}

    function ybar.bar(t) apply(raw.bar, nil, t) end
    function ybar.default(t) apply(raw.default, nil, t) end
    function ybar.set(name, t) apply(raw.set, name, t) end
    function ybar.subscribe(name, event, fn)
      if type(event) == "table" then
        for _, e in ipairs(event) do ybar.subscribe(name, e, fn) end
        return
      end
      local e = raw.subscribe(name, event, fn)
      if e then print(e) end
    end
    function ybar.delay(seconds, fn) raw.delay(seconds, fn) end
    function ybar.update() raw.update() end
    function ybar.query_table(name) return raw.query_item(name) end
    function ybar.trigger(event, env) raw.trigger(event, env or {}) end
    function ybar.push(name, values) raw.push(name, values) end
    function ybar.exec(cmd, fn) raw.exec(cmd, fn) end
    function ybar.add_event(name, notification) local e = raw.add_event(name, notification) if e then print(e) end end
    function ybar.query(target) return raw.query(target) end
    function ybar.remove(name) raw.remove(name) end

    function ybar.animate(curve, frames, fn)
      raw.animate_begin(curve, frames)
      local ok, err = pcall(fn)
      raw.animate_end()
      if not ok then error(err, 0) end
    end

    local item_methods = {}
    item_methods.__index = item_methods
    function item_methods:set(t) ybar.set(self.name, t) end
    function item_methods:subscribe(event, fn) ybar.subscribe(self.name, event, fn) end
    function item_methods:push(values) ybar.push(self.name, values) end
    function item_methods:query() return raw.query_item(self.name) end

    local function handle(name)
      return setmetatable({ name = name }, item_methods)
    end

    function ybar.add(kind, name, position, arg)
      local pos = position
      if kind == "bracket" and type(position) == "table" then
        pos = table.concat(position, ",")
      end
      if raw.add(kind, name, pos, arg) then
        local h = handle(name)
        if type(arg) == "table" then h:set(arg) end
        return h
      end
    end

    function ybar.item(name) return handle(name) end

    package.loaded["ybar"] = ybar
    """
}

/// Push nil (success) or the error string.
@MainActor
private func pushOptionalError(_ state: OpaquePointer?, _ error: String?) {
    if let error {
        lua_pushstring(state, error)
    } else {
        lua_pushnil(state)
    }
}
