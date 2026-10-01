import Foundation
import Testing
@testable import YBarKit

/// The settings layer: what a theme declares, what the user overrides, and
/// how a GUI reaches both over the socket. Headless (BarManager without
/// begin()), with the sidecar and the theme roots under a temporary home.
@MainActor
@Suite(.serialized) struct SettingsTests {
    private struct Stack {
        let barManager: BarManager
        let eventBus: EventBus
        let scheduler: AnimationScheduler
        let handler: CommandHandler
        let runtime: LuaRuntime
        let store: SettingsStore
        let root: URL
        var home: URL { root.appendingPathComponent("home") }
    }

    private static let schema: [SettingsEntry] = [
        SettingsEntry(key: "pill_height", kind: .number, defaultValue: .number(32),
                      label: "Pill height", section: "Layout", min: 20, max: 60),
        SettingsEntry(key: "colors.today", kind: .color, defaultValue: .color(0xFFFF_453A),
                      section: "Colors", apply: .live),
        SettingsEntry(key: "widgets.wifi", kind: .bool, defaultValue: .bool(true), section: "Widgets"),
        SettingsEntry(key: "icons", kind: .choice, defaultValue: .string("sf-symbols"),
                      options: ["sf-symbols", "nerd"]),
        SettingsEntry(key: "widgets.order", kind: .list, defaultValue: .list(["cpu", "wifi"]),
                      section: "Widgets"),
        SettingsEntry(key: "greeting", kind: .string, defaultValue: .string("hi"), apply: .live),
    ]

    private func makeStack(declare: Bool = true) throws -> Stack {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ybar-settings-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let themes = home.appendingPathComponent(".config/ybar/themes")
        for name in ["alpha", "beta"] {
            let directory = themes.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "ybar.bar({ height = 30 })\n".write(
                to: directory.appendingPathComponent("ybarrc.lua"), atomically: true, encoding: .utf8)
        }
        let store = SettingsStore(
            directory: root.appendingPathComponent("settings"),
            themeSource: ThemeSource(home: home, roots: [themes]))
        store.beginConfig(theme: "alpha")
        if declare { #expect(store.declare(Self.schema) == nil) }

        let barManager = try BarManager()
        let eventBus = EventBus()
        eventBus.itemsProvider = { [weak barManager] in barManager?.store.items ?? [] }
        let scheduler = AnimationScheduler()
        let handler = CommandHandler(
            barManager: barManager, eventBus: eventBus,
            scriptRunner: ScriptRunner(), scheduler: scheduler)
        handler.settingsStore = store
        let runtime = LuaRuntime(barManager: barManager, eventBus: eventBus, scheduler: scheduler)
        runtime.settingsStore = store
        return Stack(barManager: barManager, eventBus: eventBus, scheduler: scheduler,
                     handler: handler, runtime: runtime, store: store, root: root)
    }

    private func json(_ text: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(text.utf8))
        return try #require(object as? [String: Any])
    }

    private func fileContents(_ store: SettingsStore) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: store.file.path) else { return nil }
        let data = try Data(contentsOf: store.file)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func run(_ code: String, _ runtime: LuaRuntime) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ybar-settings-lua-\(UUID().uuidString).lua")
        try? code.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return runtime.runConfig(at: url)
    }

    @Test func declarationNestsDefaultsAndRejectsBadSchemas() throws {
        let stack = try makeStack()
        let table = stack.store.luaTable()
        #expect(table["pill_height"] as? Int == 32)
        let colors = try #require(table["colors"] as? [String: Any])
        #expect(colors["today"] as? UInt32 == 0xFFFF_453A)
        let widgets = try #require(table["widgets"] as? [String: Any])
        #expect(widgets["wifi"] as? Bool == true)
        #expect(widgets["order"] as? [String] == ["cpu", "wifi"])

        let before = stack.store.schema.count
        #expect(stack.store.declare([
            SettingsEntry(key: "pill_height", kind: .number, defaultValue: .number(1)),
        ])?.contains("duplicate") == true)
        // `widgets` would have to be both a table and a value.
        #expect(stack.store.declare([
            SettingsEntry(key: "widgets", kind: .bool, defaultValue: .bool(true)),
        ])?.contains("nest") == true)
        #expect(stack.store.declare([
            SettingsEntry(key: "mode", kind: .choice, defaultValue: .string("a")),
        ])?.contains("options") == true)
        #expect(stack.store.declare([
            SettingsEntry(key: "gap", kind: .number, defaultValue: .number(99), min: 0, max: 10),
        ])?.contains("at most") == true)
        #expect(stack.store.declare([
            SettingsEntry(key: "bad key", kind: .string, defaultValue: .string("")),
        ])?.contains("invalid key") == true)
        // A rejected batch declares nothing.
        #expect(stack.store.schema.count == before)
    }

    @Test func setParsesByKindAndKeepsOnlyOverrides() throws {
        let stack = try makeStack()
        let store = stack.store

        #expect(store.set(key: "pill_height", token: "30").isSuccess)
        #expect(try fileContents(store)?.keys.sorted() == ["pill_height"])
        #expect(store.set(key: "pill_height", token: "abc").errorText?.contains("not a number") == true)
        #expect(store.set(key: "pill_height", token: "70").errorText?.contains("at most") == true)
        #expect(store.set(key: "nope", token: "1").errorText?.contains("no setting") == true)

        // Text-field spellings of a color all land on ARGB.
        #expect(store.set(key: "colors.today", token: "#ff0000").value == .color(0xFFFF_0000))
        #expect(store.set(key: "colors.today", token: "#80ffffff").value == .color(0x80FF_FFFF))
        #expect(store.set(key: "colors.today", token: "0x26ffffff").value == .color(0x26FF_FFFF))
        #expect(store.set(key: "colors.today", token: "red").errorText?.contains("not a color") == true)
        // Six digits after 0x would read as alpha 0 — refused, not guessed.
        #expect(store.set(key: "colors.today", token: "0xff453a").errorText?.contains("not a color") == true)
        #expect(store.set(key: "colors.today", token: "0x").errorText?.contains("not a color") == true)

        // Already on: "yes" is a no-op, not an override.
        #expect(store.set(key: "widgets.wifi", token: "yes").isNoop)
        #expect(store.set(key: "widgets.wifi", token: "off").value == .bool(false))
        #expect(store.set(key: "widgets.wifi", token: "yes").value == .bool(true))
        #expect(store.set(key: "widgets.wifi", token: "off").value == .bool(false))
        #expect(store.set(key: "icons", token: "nerd").isSuccess)
        #expect(store.set(key: "icons", token: "emoji").errorText?.contains("one of") == true)
        #expect(store.set(key: "widgets.order", token: "wifi, cpu").value == .list(["wifi", "cpu"]))

        let file = try #require(try fileContents(store))
        #expect(file["colors.today"] as? String == "0x26ffffff")
        #expect(file["widgets.wifi"] as? Bool == false)
        #expect(file["widgets.order"] as? [String] == ["wifi", "cpu"])

        // Setting a key back to its default is a reset, not an override.
        #expect(store.set(key: "colors.today", token: "0xffff453a").isSuccess)
        #expect(try fileContents(store)?["colors.today"] == nil)
        #expect(store.override(for: try #require(store.entry(for: "colors.today"))) == nil)
    }

    /// Saving what is already in effect is not a change: no file write, no
    /// event, no reload. The Raycast form submits unchanged text often.
    @Test func settingTheValueInEffectIsANoop() throws {
        let stack = try makeStack()
        var reloads = 0
        stack.handler.onReload = { _ in reloads += 1 }
        #expect(stack.store.set(key: "pill_height", token: "32").isNoop)
        #expect(try fileContents(stack.store) == nil)
        #expect(stack.store.set(key: "pill_height", token: "30").value == .number(30))
        #expect(stack.store.set(key: "pill_height", token: "30").isNoop)
        #expect(stack.store.set(key: "pill_height", token: "30.0").isNoop)
        #expect(stack.handler.handle(arguments: ["--settings", "set", "pill_height=30"]).isEmpty)
        #expect(reloads == 0)
        #expect(stack.handler.handle(arguments: ["--settings", "set", "pill_height=31"]).isEmpty)
        #expect(reloads == 1)
    }

    /// A write that fails leaves nothing behind in memory either: the query
    /// must not report a value the file never got.
    @Test func aFailedWriteChangesNothing() throws {
        let stack = try makeStack()
        // A FILE where the settings directory should be: createDirectory fails.
        try Data().write(to: stack.store.directory)
        let failed = stack.store.set(key: "pill_height", token: "30")
        #expect(failed.errorText?.contains("could not write") == true)
        #expect(stack.store.value(for: try #require(stack.store.entry(for: "pill_height"))) == .number(32))
        #expect(stack.store.override(for: try #require(stack.store.entry(for: "pill_height"))) == nil)
    }

    /// JSON booleans and numbers bridge to the same NSNumber; a hand-edited
    /// file with the wrong type is ignored, like a wrong string is.
    @Test func sidecarValuesOfTheWrongJSONTypeAreIgnored() throws {
        let stack = try makeStack()
        try FileManager.default.createDirectory(at: stack.store.directory, withIntermediateDirectories: true)
        try Data(#"{"pill_height": true, "widgets.wifi": 0, "greeting": false, "colors.today": true}"#.utf8)
            .write(to: stack.store.file)
        stack.store.beginConfig(theme: "alpha")
        #expect(stack.store.declare(Self.schema) == nil)
        func effective(_ key: String) throws -> SettingsValue {
            stack.store.value(for: try #require(stack.store.entry(for: key)))
        }
        #expect(try effective("pill_height") == .number(32))
        #expect(try effective("widgets.wifi") == .bool(true))
        #expect(try effective("greeting") == .string("hi"))
        #expect(try effective("colors.today") == .color(0xFFFF_453A))
        // The real types still land.
        try Data(#"{"pill_height": 28, "widgets.wifi": false, "greeting": "yo"}"#.utf8).write(to: stack.store.file)
        stack.store.beginConfig(theme: "alpha")
        #expect(stack.store.declare(Self.schema) == nil)
        #expect(try effective("pill_height") == .number(28))
        #expect(try effective("widgets.wifi") == .bool(false))
        #expect(try effective("greeting") == .string("yo"))
    }

    @Test func theSidecarFollowsXDGConfigHomeLikeTheConfigDoes() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(SettingsStore.defaultDirectory(home: home, environment: [:]).path
            == "/Users/someone/.config/ybar/settings")
        #expect(SettingsStore.defaultDirectory(home: home, environment: ["XDG_CONFIG_HOME": "/tmp/xdg"]).path
            == "/tmp/xdg/ybar/settings")
        #expect(SettingsStore.defaultDirectory(home: home, environment: ["XDG_CONFIG_HOME": ""]).path
            == "/Users/someone/.config/ybar/settings")
    }

    @Test func overridesSurviveANewStoreAndUnknownKeysAreKept() throws {
        let first = try makeStack()
        #expect(first.store.set(key: "pill_height", token: "28").isSuccess)
        // A key from another version of the theme: not in today's schema.
        var raw = try #require(try fileContents(first.store))
        raw["legacy"] = "keep me"
        raw["pill_height"] = 28
        try JSONSerialization.data(withJSONObject: raw).write(to: first.store.file)

        let again = SettingsStore(directory: first.store.directory, themeSource: first.store.themeSource)
        again.beginConfig(theme: "alpha")
        #expect(again.declare(Self.schema) == nil)
        #expect(again.value(for: try #require(again.entry(for: "pill_height"))) == .number(28))
        #expect(again.set(key: "greeting", token: "yo").isSuccess)
        let after = try #require(try fileContents(again))
        #expect(after["legacy"] as? String == "keep me")
        #expect(after["pill_height"] as? Int == 28)
        #expect(after["greeting"] as? String == "yo")

        // A value that no longer fits the schema is ignored, not crashed on.
        raw = after
        raw["pill_height"] = "tall"
        try JSONSerialization.data(withJSONObject: raw).write(to: again.file)
        let third = SettingsStore(directory: first.store.directory, themeSource: first.store.themeSource)
        third.beginConfig(theme: "alpha")
        #expect(third.declare(Self.schema) == nil)
        #expect(third.value(for: try #require(third.entry(for: "pill_height"))) == .number(32))
    }

    @Test func queryReportsSchemaValuesAndOverrides() throws {
        let stack = try makeStack()
        #expect(stack.handler.handle(arguments: ["--settings", "set", "pill_height=30"]).isEmpty)
        let reply = try json(stack.handler.handle(arguments: ["--query", "settings"]))
        #expect(reply["theme"] as? String == "alpha")
        let rows = try #require(reply["schema"] as? [[String: Any]])
        #expect(rows.map { $0["key"] as? String } == Self.schema.map { $0.key })
        let height = rows[0]
        #expect(height["type"] as? String == "number")
        #expect(height["section"] as? String == "Layout")
        #expect(height["apply"] as? String == "reload")
        #expect(height["default"] as? Int == 32)
        #expect(height["value"] as? Int == 30)
        #expect(height["overridden"] as? Bool == true)
        #expect(height["min"] as? Int == 20)
        let today = rows[1]
        #expect(today["type"] as? String == "color")
        #expect(today["default"] as? String == "0xffff453a")
        #expect(today["overridden"] as? Bool == false)
        #expect(rows[3]["options"] as? [String] == ["sf-symbols", "nerd"])
        let values = try #require(reply["values"] as? [String: Any])
        #expect(values["widgets.order"] as? [String] == ["cpu", "wifi"])
        let overrides = try #require(reply["overrides"] as? [String: Any])
        #expect(overrides.keys.sorted() == ["pill_height"])
    }

    /// A live key reaches the theme as an event; a layout key re-runs the
    /// config once, however many keys the batch carried, and fires no event
    /// (the reload rebuilds everything a handler would have touched).
    @Test func liveKeysFireEventsAndLayoutKeysReloadOnce() throws {
        let stack = try makeStack()
        var environments: [[String: String]] = []
        stack.eventBus.runItemScript = { _, environment in environments.append(environment) }
        var reloads: [String?] = []
        stack.handler.onReload = { reloads.append($0) }
        _ = stack.handler.handle(arguments: [
            "--add", "item", "w", "left", "--set", "w", "script=true",
            "--subscribe", "w", "settings_change",
        ])

        #expect(stack.handler.handle(arguments: [
            "--settings", "set", "colors.today=#00ff00", "greeting=hello",
        ]).isEmpty)
        #expect(reloads.isEmpty)
        #expect(environments.count == 2)
        #expect(environments[0]["SENDER"] == "settings_change")
        #expect(environments[0]["KEY"] == "colors.today")
        #expect(environments[0]["VALUE"] == "0xff00ff00")
        #expect(environments[0]["TYPE"] == "color")
        #expect(environments[0]["INFO"] == "colors.today")
        #expect(environments[1]["KEY"] == "greeting")
        #expect(environments[1]["VALUE"] == "hello")

        #expect(stack.handler.handle(arguments: [
            "--settings", "set", "pill_height=30", "widgets.wifi=off", "greeting=again",
        ]).isEmpty)
        #expect(reloads == [nil])
        #expect(environments.count == 2)

        // Nothing changed, nothing happens.
        #expect(stack.handler.handle(arguments: ["--settings", "reset", "icons"]).isEmpty)
        #expect(reloads.count == 1)
        // A bad token reports and applies nothing else from that key.
        let bad = stack.handler.handle(arguments: ["--settings", "set", "pill_height=tall"])
        #expect(bad.contains("not a number"))
        #expect(reloads.count == 1)
        #expect(stack.handler.handle(arguments: ["--settings"]).contains("usage"))
    }

    @Test func resetRestoresTheDefaultAndRemovesAnEmptyFile() throws {
        let stack = try makeStack()
        let store = stack.store
        #expect(store.set(key: "pill_height", token: "30").isSuccess)
        #expect(store.set(key: "greeting", token: "yo").isSuccess)
        let one = store.reset(keys: ["pill_height"])
        #expect(one.changes?.map(\.value) == [.number(32)])
        #expect(try fileContents(store)?.keys.sorted() == ["greeting"])
        #expect(store.reset(keys: ["nope"]).errorText?.contains("no setting") == true)
        let all = store.reset(keys: [])
        #expect(all.changes?.count == 1)
        #expect(try fileContents(store) == nil)
        var reloads = 0
        stack.handler.onReload = { _ in reloads += 1 }
        #expect(store.set(key: "widgets.wifi", token: "off").isSuccess)
        #expect(stack.handler.handle(arguments: ["--settings", "reset"]).isEmpty)
        #expect(reloads == 1)
    }

    @Test func luaDeclaresAndReadsTheMergedTable() throws {
        let stack = try makeStack(declare: false)
        defer { stack.runtime.shutdown() }
        // The user changed it before this config run — the override is on
        // disk, the theme has not declared yet.
        try FileManager.default.createDirectory(at: stack.store.directory, withIntermediateDirectories: true)
        try Data(#"{"pill_height": 30, "widgets.order": ["wifi", "cpu"]}"#.utf8).write(to: stack.store.file)
        stack.store.beginConfig(theme: "alpha")

        let error = run("""
        local S = ybar.settings({
          { key = "pill_height", type = "number", default = 32, label = "Pill height",
            section = "Layout", min = 20, max = 60 },
          { key = "colors.today", type = "color", default = 0xffff453a, apply = "live" },
          { key = "widgets.order", type = "list", default = { "cpu", "wifi" } },
          { key = "icons", type = "enum", default = "sf-symbols", options = { "sf-symbols", "nerd" } },
          { key = "widgets.wifi", type = "bool", default = true },
        })
        ybar.bar({ height = S.pill_height })
        local c = ybar.add("item", "c", "left")
        c:set({ label = tostring(S.colors.today) .. " " .. S.widgets.order[1] .. " " .. S.icons
          .. " " .. tostring(S.widgets.wifi) })
        """, stack.runtime)
        #expect(error == nil)
        #expect(stack.barManager.settings.height == 30)
        #expect(stack.barManager.store.item(named: "c")?.label.string == "4294919482 wifi sf-symbols true")
        #expect(stack.store.schema.count == 5)
        #expect(stack.store.entry(for: "pill_height")?.min == 20)
        #expect(stack.store.entry(for: "colors.today")?.apply == .live)
        #expect(stack.store.entry(for: "icons")?.options == ["sf-symbols", "nerd"])

        // A second declaration appends (each widget file declares its own);
        // a broken one declares nothing and says so.
        #expect(run("""
        ybar.settings({ { key = "greeting", type = "string", default = "hi" } })
        local t = ybar.settings({ { key = "oops", default = 1 } })
        """, stack.runtime) == nil)
        #expect(stack.store.schema.map(\.key).contains("greeting"))
        #expect(!stack.store.schema.map(\.key).contains("oops"))
        // The query is reachable from Lua too. Nothing called beginConfig
        // between these runs (the daemon does, per reload), so the schema
        // still holds the six keys declared above.
        #expect(run("""
        local q = ybar.query_table("settings")
        ybar.add("item", "n", "left", { label = q.theme .. " " .. #q.schema })
        """, stack.runtime) == nil)
        #expect(stack.barManager.store.item(named: "n")?.label.string == "alpha 6")
    }

    @Test func themesListSwitchAndReset() throws {
        let stack = try makeStack()
        var reloads: [String?] = []
        stack.handler.onReload = { reloads.append($0) }
        var resets = 0
        stack.handler.onThemeReset = { resets += 1 }

        let listed = try JSONSerialization.jsonObject(
            with: Data(stack.handler.handle(arguments: ["--query", "themes"]).utf8))
        let rows = try #require(listed as? [[String: Any]])
        #expect(rows.map { $0["name"] as? String } == ["alpha", "beta"])
        #expect(rows.allSatisfy { $0["current"] as? Bool == false })

        #expect(stack.handler.handle(arguments: ["--theme", "use", "beta"]).isEmpty)
        let entry = stack.home.appendingPathComponent(".config/ybar/themes/beta/ybarrc.lua").path
        #expect(reloads == [entry])
        #expect(stack.store.themeSource.current() == "beta")
        let after = try #require(try JSONSerialization.jsonObject(
            with: Data(stack.handler.handle(arguments: ["--query", "themes"]).utf8)) as? [[String: Any]])
        #expect(after[1]["current"] as? Bool == true)

        #expect(stack.handler.handle(arguments: ["--theme", "use", "nope"]).contains("no theme named"))
        #expect(reloads.count == 1)
        #expect(stack.handler.handle(arguments: ["--theme", "reset"]).isEmpty)
        #expect(resets == 1)
        #expect(stack.store.themeSource.current() == nil)
        #expect(stack.handler.handle(arguments: ["--theme"]).contains("usage"))
    }

    @Test func settingsChangeIsABuiltinEvent() {
        #expect(EventBus.builtinEvents.contains("settings_change"))
        #expect(EventBus.builtinEvents.count <= 64)
    }

    /// Headless: a theme declaring settings with no daemon wired (the shipped
    /// theme checks, a REPL) gets its defaults and touches no file — and a
    /// second run on the same runtime starts a fresh schema.
    @Test func headlessDeclarationReturnsDefaults() throws {
        let barManager = try BarManager()
        let eventBus = EventBus()
        let scheduler = AnimationScheduler()
        let runtime = LuaRuntime(barManager: barManager, eventBus: eventBus, scheduler: scheduler)
        defer { runtime.shutdown() }
        let config = """
        local S = ybar.settings({ { key = "pill_height", type = "number", default = 28 } })
        ybar.bar({ height = S.pill_height })
        """
        #expect(run(config, runtime) == nil)
        #expect(barManager.settings.height == 28)
        barManager.settings.height = 0
        #expect(run(config, runtime) == nil)
        #expect(barManager.settings.height == 28)
    }

    /// `{}` is a list: an empty default for a `list` key declares fine, and
    /// a file calling `ybar.settings({})` only to read gets the merged
    /// table, not an error.
    @Test func anEmptyTableIsAnEmptyList() throws {
        let stack = try makeStack(declare: false)
        defer { stack.runtime.shutdown() }
        #expect(run("""
        local S = ybar.settings({
          { key = "hidden", type = "list", default = {} },
          { key = "pill_height", type = "number", default = 32 },
        })
        local R = ybar.settings({})
        ybar.add("item", "n", "left", { label = #S.hidden .. " " .. R.pill_height })
        """, stack.runtime) == nil)
        #expect(stack.barManager.store.item(named: "n")?.label.string == "0 32")
        #expect(stack.store.entry(for: "hidden")?.defaultValue == .list([]))
    }
}

private extension Result where Success == SettingsChange?, Failure == SettingsFailure {
    var isSuccess: Bool { if case .success = self { return true } else { return false } }
    var value: SettingsValue? { if case .success(let change) = self { return change?.value } else { return nil } }
    var isNoop: Bool { if case .success(nil) = self { return true } else { return false } }
    var errorText: String? { if case .failure(let failure) = self { return failure.message } else { return nil } }
}

private extension Result where Success == [SettingsChange], Failure == SettingsFailure {
    var changes: [SettingsChange]? { if case .success(let changes) = self { return changes } else { return nil } }
    var errorText: String? { if case .failure(let failure) = self { return failure.message } else { return nil } }
}
