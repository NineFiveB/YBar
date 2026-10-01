import Foundation

/// The knobs a theme hands to a settings UI, and where the user's choices
/// live. A theme stays the authored source of truth — nothing here ever
/// rewrites a Lua file. Instead the theme DECLARES what is tunable
/// (`ybar.settings { ... }`), the daemon keeps only the keys the user changed
/// in a sidecar JSON per theme, and the theme reads the merged result back at
/// load. A GUI (the Raycast extension, YSpot) sees the schema and the values
/// through `--query settings` and writes through `--settings set`.
///
/// Why sparse: an untouched key keeps following the theme, so a theme update
/// that changes a default reaches everyone who never overrode it, and the UI
/// can badge the rows that are still "theme default".
public struct SettingsEntry: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case number, string, bool, color, list
        /// Spelled `enum` on the wire and in Lua; `choice` only because the
        /// word is reserved in Swift.
        case choice = "enum"
    }

    /// `live`: the theme applies the change itself from a `settings_change`
    /// handler. `reload`: the daemon re-runs the config, which reads the new
    /// value at load. Anything that shapes layout at config time — heights,
    /// paddings, which widgets exist — is a reload key.
    public enum Apply: String, Sendable {
        case live, reload
    }

    public var key: String
    public var kind: Kind
    public var defaultValue: SettingsValue
    public var label: String
    public var section: String
    public var apply: Apply
    /// `enum` only: the allowed values, in display order.
    public var options: [String]
    /// `number` only.
    public var min: Double?
    public var max: Double?

    public init(key: String, kind: Kind, defaultValue: SettingsValue,
                label: String? = nil, section: String = "General",
                apply: Apply = .reload, options: [String] = [],
                min: Double? = nil, max: Double? = nil) {
        self.key = key
        self.kind = kind
        self.defaultValue = defaultValue
        self.label = label ?? key
        self.section = section
        self.apply = apply
        self.options = options
        self.min = min
        self.max = max
    }

    /// One `ybar.settings` entry table, loosely typed as Lua hands it over.
    public static func fromLua(_ table: [String: Any]) -> Result<SettingsEntry, SettingsFailure> {
        guard let key = table["key"] as? String, !key.isEmpty else {
            return .failure(SettingsFailure("[!] settings: an entry has no key"))
        }
        guard let typeName = table["type"] as? String, let kind = Kind(rawValue: typeName) else {
            return .failure(SettingsFailure("[!] settings: \(key) needs a type (number, string, bool, color, enum, list)"))
        }
        guard let defaultValue = SettingsValue.coerce(table["default"], kind: kind) else {
            return .failure(SettingsFailure("[!] settings: \(key) needs a \(kind.rawValue) default"))
        }
        var apply = Apply.reload
        if let applyName = table["apply"] as? String {
            guard let parsed = Apply(rawValue: applyName) else {
                return .failure(SettingsFailure("[!] settings: \(key) apply must be live or reload"))
            }
            apply = parsed
        }
        var options: [String] = []
        if let list = table["options"] as? [Any] {
            options = list.compactMap { $0 as? String }
        }
        func number(_ name: String) -> Double? {
            if let value = table[name] as? Double { return value }
            if let value = table[name] as? Int { return Double(value) }
            return nil
        }
        return .success(SettingsEntry(
            key: key, kind: kind, defaultValue: defaultValue,
            label: table["label"] as? String,
            section: table["section"] as? String ?? "General",
            apply: apply, options: options,
            min: number("min"), max: number("max")))
    }

    /// Dotted keys nest in the Lua table (`colors.today` → `S.colors.today`),
    /// so a segment must be a plausible identifier and no key may be a
    /// prefix of another.
    static func validKey(_ key: String) -> Bool {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        for segment in segments {
            guard let first = segment.first, first.isLetter || first == "_" else { return false }
            guard segment.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        }
        return true
    }
}

public enum SettingsValue: Equatable, Sendable {
    case number(Double)
    case string(String)
    case bool(Bool)
    case color(UInt32)
    case list([String])

    /// What `--settings set` and the `VALUE` environment variable speak:
    /// sketchybar's own spellings, so a theme can pass the token straight
    /// into `sbar.set`.
    public var token: String {
        switch self {
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
            return String(value)
        case .string(let value): return value
        case .bool(let value): return value ? "on" : "off"
        case .color(let argb): return String(format: "0x%08x", argb)
        case .list(let values): return values.joined(separator: ",")
        }
    }

    /// The JSON shape (`--query settings`, the sidecar file). Colors are the
    /// `0xAARRGGBB` string every other query already prints.
    public var json: Any {
        switch self {
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return Int(value) }
            return value
        case .string(let value): return value
        case .bool(let value): return value
        case .color(let argb): return String(format: "0x%08x", argb)
        case .list(let values): return values
        }
    }

    /// The Lua shape: colors are integers, so `colors.today = S.colors.today`
    /// drops into the existing palette tables unchanged.
    public var lua: Any {
        switch self {
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 { return Int(value) }
            return value
        case .string(let value): return value
        case .bool(let value): return value
        case .color(let argb): return argb
        case .list(let values): return values
        }
    }

    /// Parse a CLI token for a kind. Nil means the token does not fit.
    public static func parse(token: String, kind: SettingsEntry.Kind) -> SettingsValue? {
        switch kind {
        case .number:
            guard let value = Double(token.trimmingCharacters(in: .whitespaces)), value.isFinite else { return nil }
            return .number(value)
        case .string, .choice:
            return .string(token)
        case .bool:
            switch token.lowercased() {
            case "on", "true", "yes", "1": return .bool(true)
            case "off", "false", "no", "0": return .bool(false)
            default: return nil
            }
        case .color:
            return parseColor(token).map { .color($0) }
        case .list:
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return .list([]) }
            return .list(trimmed.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty })
        }
    }

    /// `0xAARRGGBB` (the CLI), `#AARRGGBB` and `#RRGGBB` (what a text field
    /// gets typed into), or a plain integer.
    static func parseColor(_ token: String) -> UInt32? {
        var text = token.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("#") {
            text = String(text.dropFirst())
            guard text.allSatisfy(\.isHexDigit) else { return nil }
            if text.count == 6 { text = "ff" + text }
            guard text.count == 8, let value = UInt32(text, radix: 16) else { return nil }
            return value
        }
        if text.hasPrefix("0x") {
            // Eight digits or nothing: `0xff453a` is the CSS habit, and read
            // as six hex digits it would be alpha 0 — an invisible accent
            // with no error to explain it.
            let digits = text.dropFirst(2)
            guard digits.count == 8, digits.allSatisfy(\.isHexDigit) else { return nil }
            return UInt32(digits, radix: 16)
        }
        guard !text.isEmpty, text.allSatisfy(\.isNumber) else { return nil }
        return UInt32(text)
    }

    /// Coerce a loosely typed value (a Lua default, a JSON file entry) into
    /// the kind. A color may arrive as an integer (Lua `0xffff453a`) or a
    /// string (the file); a number as any numeric; a list as an array of
    /// anything stringable.
    public static func coerce(_ any: Any?, kind: SettingsEntry.Kind) -> SettingsValue? {
        guard let any else { return nil }
        // A JSON `true` bridges to NSNumber(1), and `as? Double` would take
        // it; a hand-edited `"pill_height": true` must be ignored like
        // `"tall"` is, not become a height of 1.
        let boolean = isBoolean(any)
        switch kind {
        case .number:
            if boolean { return nil }
            if let value = any as? Double, value.isFinite { return .number(value) }
            if let value = any as? Int { return .number(Double(value)) }
            if let text = any as? String { return parse(token: text, kind: .number) }
            return nil
        case .string, .choice:
            if boolean { return nil }
            if let text = any as? String { return .string(text) }
            if let value = any as? Int { return .string(String(value)) }
            if let value = any as? Double { return .string(SettingsValue.number(value).token) }
            return nil
        case .bool:
            if boolean, let value = any as? Bool { return .bool(value) }
            if let text = any as? String { return parse(token: text, kind: .bool) }
            return nil
        case .color:
            if boolean { return nil }
            if let text = any as? String { return parse(token: text, kind: .color) }
            if let value = any as? UInt32 { return .color(value) }
            if let value = any as? Int, value >= 0, value <= Int(UInt32.max) { return .color(UInt32(value)) }
            if let value = any as? Double, value >= 0, value <= Double(UInt32.max), value == value.rounded() {
                return .color(UInt32(value))
            }
            return nil
        case .list:
            if let array = any as? [Any] {
                return .list(array.compactMap { element -> String? in
                    if let text = element as? String { return text }
                    if let value = element as? Int { return String(value) }
                    if let value = element as? Double { return SettingsValue.number(value).token }
                    return nil
                })
            }
            if let text = any as? String { return parse(token: text, kind: .list) }
            return nil
        }
    }

    /// Whether a loosely typed value is a boolean — a native `Bool`, or the
    /// CFBoolean that JSON `true`/`false` deserialize to. Both bridge to
    /// NSNumber, which is why `as? Double` cannot tell them apart.
    static func isBoolean(_ any: Any) -> Bool {
        guard let number = any as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    var kind: SettingsEntry.Kind {
        switch self {
        case .number: return .number
        case .string: return .string
        case .bool: return .bool
        case .color: return .color
        case .list: return .list
        }
    }
}

/// Where themes are found, for `--query themes` and `--theme use`. The same
/// roots and state file the `ybar theme` local verb uses, carried as values
/// so a test can point them at a temporary home.
public struct ThemeSource: Sendable {
    public var home: URL
    public var roots: [URL]

    public init(home: URL, roots: [URL]) {
        self.home = home
        self.roots = roots
    }

    public static func live() -> ThemeSource {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ThemeSource(
            home: home,
            roots: ThemeCatalog.roots(home: home, executable: AppBundle.executableURL(),
                                      environment: ProcessInfo.processInfo.environment))
    }

    public func themes() -> [(name: String, entry: URL)] {
        ThemeCatalog.collect(roots: roots)
    }

    public func current() -> String? {
        ThemeCatalog.currentName(home: home)
    }

    /// Record a selection, exactly as `ybar theme use` does. Returns an error line.
    public func select(_ name: String) -> String? {
        ThemeCatalog.record(name, home: home)
    }

    public func clearSelection() {
        ThemeCatalog.clearSelection(home: home)
    }
}

/// A refused declaration or write, as the `[!]` line the CLI prints.
public struct SettingsFailure: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}

/// One applied change, for the event and the reload decision.
public struct SettingsChange: Equatable, Sendable {
    public let entry: SettingsEntry
    /// The value now in effect (the default again after a reset).
    public let value: SettingsValue
}

@MainActor
public final class SettingsStore {
    /// `~/.config/ybar/settings/<theme>.json`.
    public var directory: URL
    public var themeSource: ThemeSource
    public private(set) var theme = "default"
    public private(set) var schema: [SettingsEntry] = []
    /// The sidecar as loaded, every key kept — a key the current schema does
    /// not know (an older theme version's, a widget not loaded today) is
    /// carried through untouched rather than dropped on the next save.
    private var fileValues: [String: Any] = [:]

    public init(directory: URL? = nil, themeSource: ThemeSource? = nil) {
        self.directory = directory ?? SettingsStore.defaultDirectory()
        self.themeSource = themeSource ?? ThemeSource.live()
    }

    /// `$XDG_CONFIG_HOME/ybar/settings`, else `~/.config/ybar/settings` —
    /// the same root config discovery reads, so the sidecar sits beside the
    /// config it belongs to.
    public static func defaultDirectory(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let root: URL
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            root = URL(fileURLWithPath: xdg)
        } else {
            root = home.appendingPathComponent(".config")
        }
        return root.appendingPathComponent("ybar/settings")
    }

    public var file: URL {
        directory.appendingPathComponent("\(theme).json")
    }

    /// Called before every config run: a reload re-declares from scratch and
    /// re-reads the sidecar, so a hand edit of the file is one reload away.
    /// The theme name is a file name, never a path.
    public func beginConfig(theme: String) {
        let safe = theme.replacingOccurrences(of: "/", with: "_")
        self.theme = safe.isEmpty ? "default" : safe
        schema.removeAll()
        fileValues = Self.readFile(file)
    }

    /// Register knobs. Later calls append, so each widget file can declare
    /// its own. Returns an error line and declares nothing from a batch that
    /// has one — a half-registered schema would be worse than none.
    @discardableResult
    public func declare(_ entries: [SettingsEntry]) -> String? {
        var seen = Set(schema.map(\.key))
        for entry in entries {
            guard SettingsEntry.validKey(entry.key) else {
                return "[!] settings: invalid key \"\(entry.key)\""
            }
            guard !seen.contains(entry.key) else {
                return "[!] settings: duplicate key \"\(entry.key)\""
            }
            for other in seen where other.hasPrefix(entry.key + ".") || entry.key.hasPrefix(other + ".") {
                return "[!] settings: \"\(entry.key)\" and \"\(other)\" nest into each other"
            }
            if entry.kind == .choice, entry.options.isEmpty {
                return "[!] settings: enum \"\(entry.key)\" needs options"
            }
            if let error = validate(entry.defaultValue, for: entry) {
                return "[!] settings: default for \"\(entry.key)\" \(error)"
            }
            seen.insert(entry.key)
        }
        schema += entries
        return nil
    }

    public func entry(for key: String) -> SettingsEntry? {
        schema.first { $0.key == key }
    }

    /// The user's value for a schema key, if they set one that still fits.
    public func override(for entry: SettingsEntry) -> SettingsValue? {
        guard let raw = fileValues[entry.key],
              let value = SettingsValue.coerce(raw, kind: entry.kind),
              validate(value, for: entry) == nil
        else { return nil }
        return value
    }

    /// Effective value: the override, else the theme's default.
    public func value(for entry: SettingsEntry) -> SettingsValue {
        override(for: entry) ?? entry.defaultValue
    }

    /// `--settings set key=token`. Nil on success means nothing changed:
    /// the value was already in effect, so there is nothing to apply and no
    /// reason to re-run the config.
    public func set(key: String, token: String) -> Result<SettingsChange?, SettingsFailure> {
        guard let entry = entry(for: key) else {
            return .failure(SettingsFailure("[!] settings: no setting named \"\(key)\""))
        }
        guard let value = SettingsValue.parse(token: token, kind: entry.kind) else {
            return .failure(SettingsFailure("[!] settings: \"\(token)\" is not a \(entry.kind.rawValue) (\(key))"))
        }
        if let error = validate(value, for: entry) {
            return .failure(SettingsFailure("[!] settings: \(key) \(error)"))
        }
        if value == self.value(for: entry) { return .success(nil) }
        var next = fileValues
        if value == entry.defaultValue {
            next.removeValue(forKey: key)
        } else {
            next[key] = value.json
        }
        // The file first, memory second: a write that fails must not leave
        // the query reporting a value that was never saved.
        if let error = save(next) { return .failure(SettingsFailure(error)) }
        fileValues = next
        return .success(SettingsChange(entry: entry, value: value))
    }

    /// `--settings reset [key...]`: no keys resets every schema key. Keys the
    /// schema does not know are left alone (and reported).
    public func reset(keys: [String]) -> Result<[SettingsChange], SettingsFailure> {
        let targets: [SettingsEntry]
        if keys.isEmpty {
            targets = schema
        } else {
            var found: [SettingsEntry] = []
            for key in keys {
                guard let entry = entry(for: key) else {
                    return .failure(SettingsFailure("[!] settings: no setting named \"\(key)\""))
                }
                found.append(entry)
            }
            targets = found
        }
        var changes: [SettingsChange] = []
        var next = fileValues
        for entry in targets where next[entry.key] != nil {
            next.removeValue(forKey: entry.key)
            changes.append(SettingsChange(entry: entry, value: entry.defaultValue))
        }
        if changes.isEmpty { return .success([]) }
        if let error = save(next) { return .failure(SettingsFailure(error)) }
        fileValues = next
        return .success(changes)
    }

    func validate(_ value: SettingsValue, for entry: SettingsEntry) -> String? {
        guard value.kind == (entry.kind == .choice ? .string : entry.kind) else {
            return "must be a \(entry.kind.rawValue)"
        }
        switch (entry.kind, value) {
        case (.number, .number(let number)):
            if let min = entry.min, number < min { return "must be at least \(SettingsValue.number(min).token)" }
            if let max = entry.max, number > max { return "must be at most \(SettingsValue.number(max).token)" }
        case (.choice, .string(let text)):
            if !entry.options.contains(text) {
                return "must be one of \(entry.options.joined(separator: ", "))"
            }
        default:
            break
        }
        return nil
    }

    // MARK: - Shapes

    /// `--query settings`.
    public func queryDictionary() -> [String: Any] {
        var values: [String: Any] = [:]
        var overrides: [String: Any] = [:]
        let rows: [[String: Any]] = schema.map { entry in
            let override = override(for: entry)
            let value = override ?? entry.defaultValue
            values[entry.key] = value.json
            if let override { overrides[entry.key] = override.json }
            var row: [String: Any] = [
                "key": entry.key,
                "type": entry.kind.rawValue,
                "label": entry.label,
                "section": entry.section,
                "apply": entry.apply.rawValue,
                "default": entry.defaultValue.json,
                "value": value.json,
                "overridden": override != nil,
            ]
            if entry.kind == .choice { row["options"] = entry.options }
            if let min = entry.min { row["min"] = SettingsValue.number(min).json }
            if let max = entry.max { row["max"] = SettingsValue.number(max).json }
            return row
        }
        return [
            "theme": theme,
            "file": file.path,
            "schema": rows,
            "values": values,
            "overrides": overrides,
        ]
    }

    /// The merged table `ybar.settings` returns: dotted keys nested.
    public func luaTable() -> [String: Any] {
        var root: [String: Any] = [:]
        for entry in schema {
            let segments = entry.key.split(separator: ".").map(String.init)
            root = Self.insert(value(for: entry).lua, at: segments[...], into: root)
        }
        return root
    }

    private static func insert(_ value: Any, at path: ArraySlice<String>, into table: [String: Any]) -> [String: Any] {
        var table = table
        guard let head = path.first else { return table }
        if path.count == 1 {
            table[head] = value
        } else {
            let child = table[head] as? [String: Any] ?? [:]
            table[head] = insert(value, at: path.dropFirst(), into: child)
        }
        return table
    }

    // MARK: - File

    private static func readFile(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return [:] }
        return dictionary
    }

    private func save(_ values: [String: Any]) -> String? {
        do {
            if values.isEmpty {
                if FileManager.default.fileExists(atPath: file.path) {
                    try FileManager.default.removeItem(at: file)
                }
                return nil
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: file, options: .atomic)
        } catch {
            return "[!] settings: could not write \(file.path): \(error)"
        }
        return nil
    }
}
