import Foundation

/// Declarative JSONC config tier: a `.json`/`.jsonc` file passed via `-c` is
/// translated into the same command argv batches socket clients send, so all
/// setter semantics stay defined by the command layer.
///
/// Schema:
/// ```jsonc
/// {
///   "bar": {"height": 32},
///   "defaults": {"icon.font": "SF Pro:Bold:14.0"},
///   "events": ["custom_event"],
///   "items": [
///     {"name": "clock", "position": "right",
///      "props": {"update_freq": 10, "script": "date +%H:%M"},
///      "subscribe": ["system_woke"]},
///     {"bracket": ["clock", "battery"], "name": "group", "props": {}}
///   ]
/// }
/// ```
public enum JSONCConfig {
    public enum ConfigError: Error, CustomStringConvertible, Equatable {
        case invalidJSON(String)
        case rootNotAnObject
        case badEntry(String)

        public var description: String {
            switch self {
            case .invalidJSON(let detail): return "parse error: \(detail)"
            case .rootNotAnObject: return "root must be an object"
            case .badEntry(let detail): return detail
            }
        }
    }

    /// Load a config file and feed each command through the same entry point
    /// socket clients use. Diagnostics go to stderr.
    @MainActor
    public static func run(at url: URL, handler: @MainActor ([String]) -> String) {
        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(
                Data("[!] \(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
            return
        }
        let batches: [[String]]
        do {
            batches = try commands(from: source)
        } catch {
            FileHandle.standardError.write(
                Data("[!] \(url.lastPathComponent): \(error)\n".utf8))
            return
        }
        for argv in batches {
            let output = handler(argv)
            if !output.isEmpty {
                FileHandle.standardError.write(Data("\(output)\n".utf8))
            }
        }
        // Boot population: the Lua tier ends with ybar.update() and shell
        // configs write --update themselves; without it, subscription-driven
        // items (no update_freq) stay blank until their event next fires.
        if !batches.isEmpty { _ = handler(["--update"]) }
    }

    /// Full pipeline: JSONC text → ordered command argv arrays.
    public static func commands(from source: String) throws -> [[String]] {
        let data = Data(sanitize(source).utf8)
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            let info = (error as NSError).userInfo
            let detail = info[NSDebugDescriptionErrorKey] as? String
                ?? (error as NSError).localizedDescription
            throw ConfigError.invalidJSON(detail)
        }
        guard let root = parsed as? [String: Any] else { throw ConfigError.rootNotAnObject }
        return try translate(root)
    }

    // MARK: - JSONC → strict JSON

    public static func sanitize(_ source: String) -> String {
        stripTrailingCommas(stripComments(source))
    }

    /// Remove `//` and `/* */` comments outside string literals. Newlines
    /// terminating line comments are kept.
    static func stripComments(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                result.append(scalar)
                if scalar == "\\", index + 1 < scalars.count {
                    result.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == "\"" { inString = false }
                index += 1
                continue
            }
            if scalar == "/", index + 1 < scalars.count {
                if scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                    continue
                }
                if scalars[index + 1] == "*" {
                    index += 2
                    while index + 1 < scalars.count,
                          !(scalars[index] == "*" && scalars[index + 1] == "/") {
                        index += 1
                    }
                    index = min(index + 2, scalars.count)
                    continue
                }
            }
            if scalar == "\"" { inString = true }
            result.append(scalar)
            index += 1
        }
        return String(result)
    }

    /// Drop a `,` whose next non-whitespace scalar closes its container.
    /// Runs after comment stripping, so whitespace lookahead suffices.
    static func stripTrailingCommas(_ source: String) -> String {
        let scalars = Array(source.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < scalars.count {
            let scalar = scalars[index]
            if inString {
                result.append(scalar)
                if scalar == "\\", index + 1 < scalars.count {
                    result.append(scalars[index + 1])
                    index += 2
                    continue
                }
                if scalar == "\"" { inString = false }
                index += 1
                continue
            }
            if scalar == "\"" { inString = true }
            if scalar == "," {
                var lookahead = index + 1
                while lookahead < scalars.count,
                      CharacterSet.whitespacesAndNewlines.contains(scalars[lookahead]) {
                    lookahead += 1
                }
                if lookahead < scalars.count,
                   scalars[lookahead] == "}" || scalars[lookahead] == "]" {
                    index += 1
                    continue
                }
            }
            result.append(scalar)
            index += 1
        }
        return String(result)
    }

    // MARK: - Translation

    static func translate(_ root: [String: Any]) throws -> [[String]] {
        var commands: [[String]] = []

        // Valid JSON with a misspelled section ("item", "default") would
        // otherwise produce an empty bar with zero diagnostics.
        let knownSections: Set<String> = ["bar", "defaults", "events", "items"]
        for key in root.keys where !knownSections.contains(key) {
            warn("unknown top-level key \"\(key)\" (expected bar/defaults/events/items)")
        }

        if let bar = root["bar"] {
            guard let bar = bar as? [String: Any] else {
                throw ConfigError.badEntry("\"bar\" must be an object")
            }
            let tokens = try propertyTokens(bar, context: "bar")
            if !tokens.isEmpty { commands.append(["--bar"] + tokens) }
        }

        if let defaults = root["defaults"] {
            guard let defaults = defaults as? [String: Any] else {
                throw ConfigError.badEntry("\"defaults\" must be an object")
            }
            let tokens = try propertyTokens(defaults, context: "defaults")
            if !tokens.isEmpty { commands.append(["--default"] + tokens) }
        }

        if let events = root["events"] {
            guard let events = events as? [String] else {
                throw ConfigError.badEntry("\"events\" must be an array of strings")
            }
            for event in events { commands.append(["--add", "event", event]) }
        }

        if let items = root["items"] {
            guard let items = items as? [Any] else {
                throw ConfigError.badEntry("\"items\" must be an array")
            }
            for (index, element) in items.enumerated() {
                try translateItem(element, at: index, into: &commands)
            }
        }

        return commands
    }

    private static func warn(_ message: String) {
        FileHandle.standardError.write(Data("[?] jsonc: \(message)\n".utf8))
    }

    private static func translateItem(
        _ element: Any, at index: Int, into commands: inout [[String]]
    ) throws {
        guard let entry = element as? [String: Any] else {
            throw ConfigError.badEntry("items[\(index)] must be an object")
        }
        let knownKeys: Set<String> = ["name", "bracket", "position", "props", "subscribe"]
        for key in entry.keys where !knownKeys.contains(key) {
            warn("items[\(index)]: unknown key \"\(key)\" (expected name/bracket/position/props/subscribe)")
        }
        guard let name = entry["name"] as? String, !name.isEmpty else {
            throw ConfigError.badEntry("items[\(index)] needs a \"name\"")
        }
        if let members = entry["bracket"] {
            guard let members = members as? [String], !members.isEmpty else {
                throw ConfigError.badEntry(
                    "items[\(index)].bracket must be a non-empty array of member names")
            }
            commands.append(["--add", "bracket", name] + members)
        } else {
            let position = entry["position"] as? String ?? "left"
            commands.append(["--add", "item", name, position])
        }
        if let props = entry["props"] {
            guard let props = props as? [String: Any] else {
                throw ConfigError.badEntry("items[\(index)].props must be an object")
            }
            let tokens = try propertyTokens(props, context: "items[\(index)].props")
            if !tokens.isEmpty { commands.append(["--set", name] + tokens) }
        }
        if let subscribe = entry["subscribe"] {
            guard let events = subscribe as? [String], !events.isEmpty else {
                throw ConfigError.badEntry(
                    "items[\(index)].subscribe must be a non-empty array of event names")
            }
            commands.append(["--subscribe", name] + events)
        }
    }

    /// Object → `key=value` tokens, keys sorted (JSON objects carry no order;
    /// sorting keeps the emitted commands deterministic).
    private static func propertyTokens(
        _ properties: [String: Any], context: String
    ) throws -> [String] {
        try properties.keys.sorted().map { key in
            guard let value = stringify(properties[key]!) else {
                throw ConfigError.badEntry(
                    "\(context).\(key): value must be a string, number, or boolean")
            }
            return "\(key)=\(value)"
        }
    }

    /// Scalar JSON value → the exact form the command layer parses. Booleans
    /// map to on/off; integral numbers drop the fraction (Int-typed properties
    /// reject "10.0").
    static func stringify(_ value: Any) -> String? {
        if let string = value as? String { return string }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "on" : "off"
        }
        let double = number.doubleValue
        if double == double.rounded(), abs(double) < 1e15 {
            return "\(Int64(double))"
        }
        return "\(double)"
    }
}
