import Foundation

/// Splits an argv payload into domain batches, sketchybar-style: a token starting
/// with `--` opens a domain; following tokens belong to it until the next token
/// starting with `-`. One message can carry many domains
/// (`--add item x left --set x label=hi --subscribe x system_woke`).
public enum CommandParser {
    public struct Batch: Equatable {
        public let domain: String
        public let args: [String]

        public init(domain: String, args: [String]) {
            self.domain = domain
            self.args = args
        }
    }

    public static func batches(from tokens: [String]) -> [Batch] {
        var batches: [Batch] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.hasPrefix("--") else {
                index += 1
                continue
            }
            var args: [String] = []
            var cursor = index + 1
            while cursor < tokens.count, !tokens[cursor].hasPrefix("-") || isValue(tokens[cursor]) {
                args.append(tokens[cursor])
                cursor += 1
            }
            batches.append(Batch(domain: String(token.dropFirst(2)), args: args))
            index = cursor
        }
        return batches
    }

    /// A `-`-prefixed token that is clearly a value, not a flag: a negative number
    /// (`--set x y_offset=-2` arrives pre-split only in key=value form, but
    /// `--push graph -0.5` style args need this).
    static func isValue(_ token: String) -> Bool {
        guard token.count > 1 else { return false }
        let afterDash = token.dropFirst()
        return afterDash.first!.isNumber || afterDash.first == "."
    }

    /// Split `key=value` on the first `=`.
    public static func keyValue(_ token: String) -> (key: String, value: String)? {
        guard let separator = token.firstIndex(of: "=") else { return nil }
        return (String(token[token.startIndex..<separator]),
                String(token[token.index(after: separator)...]))
    }
}
