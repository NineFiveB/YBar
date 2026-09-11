import CoreText
import Foundation
import Testing
@testable import YBarKit

/// The text-metric golden fixture docs/WINDOWS-PORT.md §14 assigns to the
/// macOS side: `ShapedLine` values (the +1.5 width, ink bounds, typographic
/// ascent/descent) for a fixed string table in a font vendored with the
/// repo, so the port's DirectWrite accumulation can be checked
/// integer-exactly against CoreText's glyph-path bounds, and so a change in
/// the reference measurement shows up here first.
///
/// The font is `YBarTestSans-Regular.ttf`, a renamed glyph subset of Source
/// Sans 3 (OFL 1.1, see the licence file beside it) registered for this
/// process only, with no layout features and no hinting: widths are plain
/// advances plus ink. `YBAR_EXPORT_GOLDENS=1 make test` rewrites
/// Tests/Fixtures/text-metrics.json from the current measurement; a plain run
/// replays it.
@MainActor
@Suite(.serialized) struct TextMetricGoldenTests {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")
    static let fontFile = fixtures.appendingPathComponent("YBarTestSans-Regular.ttf")
    static let goldenFile = fixtures.appendingPathComponent("text-metrics.json")
    static let family = "YBar Test Sans"
    static let postScriptName = "YBarTestSans-Regular"

    /// What a status bar shows: times, percentages, mixed case, punctuation,
    /// diacritics, dashes, an ellipsis, whitespace (ink excludes it, so the
    /// padded string and the lone space pin that), narrow and wide runs, and
    /// descenders for the y-extent.
    static let strings = [
        "12:00", "Mon 8 Sep", "100%", "Battery 75%", "Wi-Fi", "iiii", "WWWW", "a", " ",
        " padded ", "Café – Ünïcode…", "The quick brown fox", "0123456789", "°C", "yjpq",
        "A—B", "(nested) [brackets] {braces}", "ç",
    ]
    static let sizes: [Float] = [12, 13, 14, 16]

    struct Entry: Codable, Equatable {
        let string: String
        let font: String
        let size: Float
        let width: Double
        let inkWidth: Double
        let inkMinX: Double
        let inkMinY: Double
        let inkMaxY: Double
        let ascent: Double
        let descent: Double
    }

    struct Fixture: Codable {
        let font: String
        let postScriptName: String
        let widthFormula: String
        let entries: [Entry]
    }

    /// Registered once per process; a second registration of the same file
    /// reports alreadyRegistered, which is success for our purposes.
    static let fontRegistered: Bool = {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(fontFile as CFURL, .process, &error) { return true }
        let code = error.map { CFErrorGetCode($0.takeRetainedValue()) } ?? 0
        return code == CTFontManagerError.alreadyRegistered.rawValue
    }()

    private static func rounded(_ value: CGFloat) -> Double {
        (Double(value) * 10_000).rounded() / 10_000
    }

    static func measure() throws -> [Entry] {
        try #require(fontRegistered, "could not register \(fontFile.path)")
        let cache = FontCache()
        var entries: [Entry] = []
        for size in sizes {
            var spec = FontSpec()
            spec.family = family
            spec.size = size
            // A fallback to the system font would measure something else and
            // still produce numbers; the PostScript name proves it is ours.
            let resolved = CTFontCopyPostScriptName(cache.font(for: spec)) as String
            try #require(resolved == postScriptName, "resolved \(resolved), not the vendored subset")
            for string in strings {
                let shaped = cache.shapedLine(text: string, spec: spec)
                entries.append(Entry(
                    string: string, font: family, size: size,
                    width: Double(shaped.width),
                    inkWidth: rounded(shaped.inkWidth),
                    inkMinX: rounded(shaped.inkMinX),
                    inkMinY: rounded(shaped.inkMinY),
                    inkMaxY: rounded(shaped.inkMaxY),
                    ascent: rounded(shaped.ascent),
                    descent: rounded(shaped.descent)))
            }
        }
        return entries
    }

    @Test func goldensMatchOrAreExported() throws {
        let measured = try Self.measure()
        if ProcessInfo.processInfo.environment["YBAR_EXPORT_GOLDENS"] == "1" {
            let fixture = Fixture(
                font: Self.family, postScriptName: Self.postScriptName,
                widthFormula: "width = Int(inkWidth + 1.5); ink from CTLineGetBoundsWithOptions(.useGlyphPathBounds)",
                entries: measured)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fixture).write(to: Self.goldenFile)
            let note = "exported \(measured.count) golden entries to \(Self.goldenFile.path); re-run without YBAR_EXPORT_GOLDENS"
            Issue.record(Comment(rawValue: note))
            return
        }

        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.goldenFile))
        #expect(fixture.postScriptName == Self.postScriptName)
        #expect(fixture.entries.count == measured.count)
        for (golden, current) in zip(fixture.entries, measured) {
            let label = "\"\(golden.string)\" @ \(golden.size)"
            #expect(golden.string == current.string, "table order changed at \(label)")
            #expect(golden.size == current.size, "table order changed at \(label)")
            // The layout width is the contract: integer-exact.
            #expect(golden.width == current.width, "width of \(label)")
            // Ink and typographic extents: path bounds are deterministic, but
            // give a hundredth of a point of slack for a future CoreText.
            #expect(abs(golden.inkWidth - current.inkWidth) < 0.01, "inkWidth of \(label)")
            #expect(abs(golden.inkMinX - current.inkMinX) < 0.01, "inkMinX of \(label)")
            #expect(abs(golden.inkMinY - current.inkMinY) < 0.01, "inkMinY of \(label)")
            #expect(abs(golden.inkMaxY - current.inkMaxY) < 0.01, "inkMaxY of \(label)")
            #expect(abs(golden.ascent - current.ascent) < 0.01, "ascent of \(label)")
            #expect(abs(golden.descent - current.descent) < 0.01, "descent of \(label)")
        }
    }

    @Test func goldenWidthsFollowTheFormulaAndInkExcludesWhitespace() throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.goldenFile))
        for entry in fixture.entries {
            #expect(entry.width == Double(FontCache.layoutWidth(ink: CGFloat(entry.inkWidth))), "\(entry.string)")
        }
        // A lone space has no ink; " padded " measures like "padded".
        for size in Self.sizes {
            let at = { (string: String) in fixture.entries.first { $0.string == string && $0.size == size } }
            #expect(at(" ")?.inkWidth == 0)
            #expect(at(" ")?.width == 1)
            let padded = try #require(at(" padded "))
            #expect(padded.inkMinX > 0, "leading space shifts the ink box right")
        }
    }
}
