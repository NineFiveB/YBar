import Foundation
import Testing
@testable import YBarKit

// MARK: - JSONC sanitizing

@Suite struct JSONCSanitizeTests {
    @Test func lineCommentsStripped() {
        let source = """
        {
          // leading comment
          "a": 1 // trailing comment
        }
        """
        let commands = try? JSONCConfig.commands(from: source)
        #expect(commands == [])
    }

    @Test func blockCommentsStripped() {
        let source = "{ /* one */ \"bar\": { /* two\n spans lines */ \"height\": 32 } }"
        #expect(try! JSONCConfig.commands(from: source) == [["--bar", "height=32"]])
    }

    @Test func commentMarkersInsideStringsSurvive() {
        let source = "{ \"bar\": { \"color\": \"http://not-a-comment\" } }"
        #expect(try! JSONCConfig.commands(from: source)
            == [["--bar", "color=http://not-a-comment"]])
        let block = "{ \"bar\": { \"color\": \"/* kept */\" } }"
        #expect(try! JSONCConfig.commands(from: block)
            == [["--bar", "color=/* kept */"]])
    }

    @Test func escapedQuoteDoesNotEndString() {
        let source = "{ \"bar\": { \"color\": \"a\\\"b // still string\" } }"
        #expect(try! JSONCConfig.commands(from: source)
            == [["--bar", "color=a\"b // still string"]])
    }

    @Test func trailingCommasAllowed() {
        let source = """
        {
          "events": ["one", "two",],
          "bar": {"height": 30,},
        }
        """
        #expect(try! JSONCConfig.commands(from: source) == [
            ["--bar", "height=30"],
            ["--add", "event", "one"],
            ["--add", "event", "two"],
        ])
    }

    @Test func commaInsideStringKept() {
        let source = "{ \"bar\": { \"color\": \"a, ]\" } }"
        #expect(try! JSONCConfig.commands(from: source) == [["--bar", "color=a, ]"]])
    }

    @Test func unterminatedBlockCommentDoesNotCrash() {
        #expect(try! JSONCConfig.commands(from: "{ \"bar\": {\"height\": 1} } /* open")
            == [["--bar", "height=1"]])
    }
}

// MARK: - Value coercion

@Suite struct JSONCValueTests {
    @Test func booleansBecomeOnOff() throws {
        let commands = try JSONCConfig.commands(
            from: "{ \"defaults\": { \"icon.drawing\": false, \"label.drawing\": true } }")
        #expect(commands == [["--default", "icon.drawing=off", "label.drawing=on"]])
    }

    @Test func integralNumbersDropFraction() throws {
        let commands = try JSONCConfig.commands(
            from: "{ \"bar\": { \"height\": 32, \"y_offset\": -2, \"blur_radius\": 20.0 } }")
        #expect(commands == [["--bar", "blur_radius=20", "height=32", "y_offset=-2"]])
    }

    @Test func fractionalNumbersKeepDecimals() throws {
        let commands = try JSONCConfig.commands(
            from: "{ \"defaults\": { \"icon.color.alpha\": 0.5 } }")
        #expect(commands == [["--default", "icon.color.alpha=0.5"]])
    }

    @Test func stringsPassThroughVerbatim() throws {
        let commands = try JSONCConfig.commands(
            from: "{ \"defaults\": { \"label\": \"a=b c\" } }")
        #expect(commands == [["--default", "label=a=b c"]])
    }

    @Test func compositeValuesRejected() {
        #expect(throws: JSONCConfig.ConfigError.self) {
            try JSONCConfig.commands(from: "{ \"bar\": { \"height\": [1, 2] } }")
        }
    }
}

// MARK: - Full translation

@Suite struct JSONCTranslationTests {
    @Test func fullConfigProducesOrderedCommands() throws {
        let source = """
        // demo config
        {
          "bar": {"height": 32, "color": "0xcc1e1e2e"},
          "defaults": {"icon.color": "0xffcdd6f4", "label.color": "0xffcdd6f4"},
          "events": ["demo_refresh"],
          "items": [
            {
              "name": "clock",
              "position": "right",
              "props": {
                "update_freq": 10,
                "script": "date +%H:%M",
                "icon.drawing": false, // booleans coerce
              },
              "subscribe": ["system_woke", "demo_refresh"],
            },
            {
              "bracket": ["clock", "battery"],
              "name": "status_group",
              "props": {"background.corner_radius": 8},
            },
          ],
        }
        """
        #expect(try JSONCConfig.commands(from: source) == [
            ["--bar", "color=0xcc1e1e2e", "height=32"],
            ["--default", "icon.color=0xffcdd6f4", "label.color=0xffcdd6f4"],
            ["--add", "event", "demo_refresh"],
            ["--add", "item", "clock", "right"],
            ["--set", "clock", "icon.drawing=off", "script=date +%H:%M", "update_freq=10"],
            ["--subscribe", "clock", "system_woke", "demo_refresh"],
            ["--add", "bracket", "status_group", "clock", "battery"],
            ["--set", "status_group", "background.corner_radius=8"],
        ])
    }

    @Test func positionDefaultsToLeft() throws {
        let commands = try JSONCConfig.commands(
            from: "{ \"items\": [ { \"name\": \"x\" } ] }")
        #expect(commands == [["--add", "item", "x", "left"]])
    }

    @Test func rootMustBeObject() {
        #expect(throws: JSONCConfig.ConfigError.rootNotAnObject) {
            try JSONCConfig.commands(from: "[1, 2]")
        }
    }

    @Test func itemWithoutNameRejected() {
        #expect(throws: JSONCConfig.ConfigError.badEntry("items[0] needs a \"name\"")) {
            try JSONCConfig.commands(from: "{ \"items\": [ { \"position\": \"left\" } ] }")
        }
    }

    @Test func malformedJSONReported() {
        #expect(throws: JSONCConfig.ConfigError.self) {
            try JSONCConfig.commands(from: "{ \"bar\": ")
        }
    }

    @Test func shippedExampleTranslates() throws {
        let example = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/jsonc-demo/ybar.jsonc")
        let source = try String(contentsOf: example, encoding: .utf8)
        let commands = try JSONCConfig.commands(from: source)
        #expect(commands.first == ["--bar", "color=0xdd1e1e2e", "height=32", "topmost=on"])
        #expect(commands.contains(["--add", "item", "clock", "right"]))
        #expect(commands.contains(["--add", "bracket", "status_group", "clock", "battery"]))
        #expect(commands.contains(["--subscribe", "battery", "power_source_change", "battery_change"]))
    }
}
