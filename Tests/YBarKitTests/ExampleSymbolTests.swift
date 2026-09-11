import AppKit
import Foundation
import Testing
@testable import YBarKit

/// Every `sf:<name>` the shipped configs use must resolve: a typo or a
/// symbol that never existed renders as nothing, and the examples are the
/// first thing a new user runs. Gated to macOS 26 because
/// NSImage(systemSymbolName:) is nil for symbols newer than the host, so an
/// older leg would fail on names that are fine on the current release.
@Suite struct ExampleSymbolTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Symbol name -> the config files that use it, from every Lua, JSONC and
    /// shell config under `directory`. A captured name ending in "." is the
    /// prefix of a runtime concatenation (`"sf:battery." .. level`), not a
    /// symbol, and is skipped.
    static func symbolNames(under directory: URL) throws -> [String: [String]] {
        let regex = try NSRegularExpression(pattern: "sf:([A-Za-z0-9._-]+)")
        var names: [String: Set<String>] = [:]
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let file = url.lastPathComponent
            guard ["lua", "jsonc", "sh"].contains(url.pathExtension) || file == "ybarrc" else { continue }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let name = String(text[range])
                guard !name.hasSuffix(".") else { continue }
                names[name, default: []].insert(file)
            }
        }
        return names.mapValues { $0.sorted() }
    }

    @Test func theSweepSeesTheShippedConfigs() throws {
        // Guards the regex and the walk: an empty sweep would pass vacuously.
        let names = try Self.symbolNames(under: Self.repoRoot.appendingPathComponent("examples"))
        #expect(names["clock"] != nil)
        #expect(names["cpu"] != nil)
    }

    @Test func everyShippedSymbolResolvesOnTheCurrentRelease() throws {
        guard #available(macOS 26, *) else { return }
        let examples = try Self.symbolNames(under: Self.repoRoot.appendingPathComponent("examples"))
        let themes = try Self.symbolNames(under: Self.repoRoot.appendingPathComponent("themes"))
        let names = examples.merging(themes) { $0 + $1 }
        for (name, files) in names.sorted(by: { $0.key < $1.key }) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    "sf:\(name) in \(files.joined(separator: ", "))")
        }
    }
}
