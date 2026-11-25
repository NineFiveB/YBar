import Foundation
import Testing
@testable import YBarKit

/// Wiring checks on the SHIPPED example themes: the sketchybar-port helpers
/// run through the real Lua runtime, headless (BarManager without begin(),
/// so no windows are created). The themes are the first thing a new user
/// runs, and their interaction wiring has no other coverage.
@MainActor
@Suite(.serialized) struct ThemeWiringTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static var portRoot: URL { repoRoot.appendingPathComponent("examples/sketchybar-port") }

    /// The runtime holds barManager/eventBus/scheduler `unowned`, so the
    /// stack has to outlive it — every member is retained here on purpose.
    private struct Stack {
        let barManager: BarManager
        let eventBus: EventBus
        let scheduler: AnimationScheduler
        let runtime: LuaRuntime
    }

    private func makeStack() throws -> Stack {
        let barManager = try BarManager()
        let eventBus = EventBus()
        eventBus.itemsProvider = { [weak barManager] in barManager?.store.items ?? [] }
        let scheduler = AnimationScheduler()
        let runtime = LuaRuntime(barManager: barManager, eventBus: eventBus, scheduler: scheduler)
        return Stack(barManager: barManager, eventBus: eventBus, scheduler: scheduler, runtime: runtime)
    }

    private func run(_ code: String, _ runtime: LuaRuntime) -> String? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ybar-theme-test-\(UUID().uuidString).lua")
        try? code.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return runtime.runConfig(at: url)
    }

    /// A multi-line popup cell (device name over connection status) is ONE
    /// click target, so hovering either line must light both plates.
    ///
    /// The regression this pins: the runtime keeps exactly one callback per
    /// (item, event) — LuaRuntime.subscribe unrefs the previous one — so
    /// wiring the cell as "each row hovers itself, plus each row hovers its
    /// sibling" left only the sibling handler alive and every line lit its
    /// neighbour instead of itself.
    @Test func hoverGroupLightsEveryRowInTheCellFromEitherRow() throws {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        let error = run("""
        package.path = "\(Self.portRoot.path)/?.lua;" .. package.path
        sbar = require("sketchybar")
        -- Land fades immediately: this test pins WHICH plates a hover drives,
        -- not the curve the engine drives them with.
        sbar.animate = function(_, _, fn) fn() end
        local hover = require("helpers.hover")
        local name = sbar.add("item", "dev.1", {})
        local status = sbar.add("item", "devstatus.1", {})
        hover.rowGroup({ name, status })
        """, stack.runtime)
        #expect(error == nil)

        let name = try #require(stack.barManager.store.item(named: "dev.1"))
        let status = try #require(stack.barManager.store.item(named: "devstatus.1"))
        let hoverTone: UInt32 = 0x16FF_FFFF   // colors.row_hover
        #expect(name.background.color.argb == 0)
        #expect(status.background.color.argb == 0)

        for hovered in [name, status] {
            #expect(stack.runtime.handleEvent(item: hovered,
                                              environment: ["SENDER": "mouse.entered"]))
            #expect(name.background.color.argb == hoverTone,
                    "hovering \(hovered.name) must light the name row")
            #expect(status.background.color.argb == hoverTone,
                    "hovering \(hovered.name) must light the status row")

            #expect(stack.runtime.handleEvent(item: hovered,
                                              environment: ["SENDER": "mouse.exited"]))
            #expect(name.background.color.argb == 0)
            #expect(status.background.color.argb == 0)
        }
    }

    /// The Bluetooth popup's paired cells must be wired by a SINGLE hover
    /// call. Two calls naming the same rows is the shape that silently loses
    /// a subscription, and the symptom (a highlight one line off) is easy to
    /// reintroduce and hard to spot in a diff.
    @Test func pairedBluetoothRowsTakeExactlyOneHoverRegistration() throws {
        let source = try String(
            contentsOf: Self.portRoot.appendingPathComponent("items/widgets/bluetooth.lua"),
            encoding: .utf8)
        let hoverCalls = source.split(separator: "\n").filter {
            $0.contains("hover.") && $0.contains("paired_")
        }
        #expect(hoverCalls.count == 1, "paired rows wired by \(hoverCalls.count) hover calls")
    }

    /// The Spaces switch may only react to `swap_menus_and_spaces` when the
    /// opt-in menus helper exists. Without it (every Homebrew install)
    /// items/menus.lua returns before registering the swap handler, so the
    /// event swaps nothing — an indicator that still flipped its glyph would
    /// show OFF with the workspace pills right there beside it.
    @Test func theSpacesSwitchOnlyReactsWhenTheMenusHelperIsThere() throws {
        let items = Self.portRoot.appendingPathComponent("items")
        var checked = 0
        // menus.lua's own swap handler needs no textual guard: it is
        // registered past the probe's early return, so it only exists when
        // the helper does.
        for file in try FileManager.default.contentsOfDirectory(atPath: items.path)
        where file.hasSuffix(".lua") && file != "menus.lua" {
            let lines = try String(contentsOf: items.appendingPathComponent(file), encoding: .utf8)
                .components(separatedBy: "\n")
            for (index, line) in lines.enumerated()
            where line.contains(#"subscribe("swap_menus_and_spaces""#) {
                checked += 1
                let preceding = lines[max(0, index - 8)..<index]
                #expect(preceding.contains { $0.contains("if MENUS_HELPER_AVAILABLE then") },
                        "\(file):\(index + 1) reacts to the swap with no helper guard")
            }
        }
        // An empty sweep would pass vacuously: both adapters carry the switch.
        #expect(checked == 2, "expected the two spaces adapters, saw \(checked) subscribers")
    }

    // MARK: - The clock and the recording dot

    /// Lua preamble for the pure helper: the live geometry of the report
    /// that started this — a 1512pt notched built-in (display 1) and a
    /// 1103pt Sidecar (display 2), the clock pill ending 8pt from each
    /// display's right edge — and a bar that covers the menu bar.
    private var dotPreamble: String {
        """
        package.path = "\(Self.portRoot.path)/?.lua;" .. package.path
        local dot = require("helpers.recording_dot")
        local bar = { topmost = "on", position = "top", margin = 0, y_offset = 0, height = 40 }
        local function rect(x, w) return { origin = { x, 0 }, size = { w, 40 } } end
        local rects = { ["display-1"] = rect(1410, 94), ["display-2"] = rect(1001, 94) }
        local function on(frames) return { RECORDING = "on", RECORDING_FRAMES = frames } end
        local function eq(got, want, what)
          assert(got == want, what .. ": got " .. tostring(got) .. ", want " .. tostring(want))
        end

        """
    }

    private func runDot(_ code: String) throws -> String? {
        let stack = try makeStack()
        defer { stack.runtime.shutdown() }
        return run(dotPreamble + code, stack.runtime)
    }

    /// macOS draws the dot on every display and one clock item serves every
    /// bar, so the pill opens by the largest room any of them needs: 18pt
    /// for the built-in's dot (1504 - 1481 - 5), 9 for the Sidecar's.
    @Test func theClockOpensForTheLargestIndicatorOnAnyOfItsBars() throws {
        let error = try runDot("""
        eq(dot.padding(on("1:1481,3,28,28 2:1081,-6,28,28"), rects, bar, 8), 18, "both displays")
        eq(dot.padding(on("2:1081,-6,28,28 1:1481,3,28,28"), rects, bar, 8), 18, "either order")
        eq(dot.padding(on("1:1481,3,28,28 2:1081,-6,28,28"),
                       { ["display-2"] = rect(1001, 94) }, bar, 8), 9, "a bar on the Sidecar only")
        eq(dot.padding(on("2:1081,-6,28,28"), rects, bar, 8), 9, "a dot on the Sidecar only")
        eq(dot.padding(on("1:1481,3,28,28"), rects, bar, 8), 18, "a dot on the built-in only")
        eq(dot.padding({ RECORDING = "off" }, rects, bar, 8), 8, "off")
        eq(dot.padding({}, rects, bar, 8), 8, "an event that says nothing")
        eq(dot.padding(nil, rects, bar, 8), 8, "no env")
        """)
        #expect(error == nil, "\(error ?? "")")
    }

    /// The regression itself. The Sidecar's dot sits at desktop x = -22; read
    /// against display 1's bar that asked for a 1521pt hole, the pill crossed
    /// the notch, and the next reading (from the displaced edge) asked for
    /// 673. Neither number, nor the layout they left behind, opens anything.
    @Test func anotherDisplaysCoordinatesOpenNothing() throws {
        let error = try runDot("""
        eq(dot.padding(on("1:-22,-6,28,28"), rects, bar, 8), 8, "the Sidecar's desktop x on display 1")
        local exploded = { ["display-1"] = rect(-111, 767), ["display-2"] = rect(328, 767) }
        eq(dot.padding(on("1:1481,3,28,28 2:1081,-6,28,28"), exploded, bar, 8), 9,
           "the layout the bug left behind")
        """)
        #expect(error == nil, "\(error ?? "")")
    }

    /// Defence in depth: whatever the event carries, the pill opens by no
    /// more than the ceiling. An ask past it is dropped, not clamped — room
    /// opened for a dot that is not there is still wrong.
    @Test func nothingOpensTheClockPastItsBound() throws {
        let error = try runDot("""
        local lo, hi = math.huge, -math.huge
        local function see(pad)
          assert(type(pad) == "number", "not a number: " .. tostring(pad))
          lo, hi = math.min(lo, pad), math.max(hi, pad)
        end
        for _, right in ipairs({ 656, 1095, 1504, 1512, 3000 }) do
          for _, margin in ipairs({ 0, 10, 300 }) do
            local b = { topmost = "on", position = "top", margin = margin, y_offset = 0, height = 40 }
            local r = { ["display-1"] = rect(right - 94, 94), ["display-2"] = rect(right - 94, 94) }
            for x = -2000, 4000 do
              see(dot.padding(on(string.format("1:%d,3,28,28 2:%d,-6,28,28", x, x)), r, b, 8))
              see(dot.padding({ RECORDING = "on", RECORDING_X = tostring(x) }, r, b, 8))
            end
          end
        end
        eq(lo, 8, "never under the resting padding")
        eq(hi, 40, "never over the ceiling")

        eq(dot.padding(on("1:1459,3,28,28"), rects, bar, 8), 40, "exactly the ceiling")
        eq(dot.padding(on("1:1458,3,28,28"), rects, bar, 8), 8, "one past it is not this pill's dot")

        for _, junk in ipairs({ "", "abc", "1:nan,3,28,28", "1:1e999,3,28,28",
                                "1:99999999999999999999999,3,28,28", "1:1481",
                                "1:1481.5,3,28,28", "0x10:1481,3,28,28" }) do
          local pad = dot.padding(on(junk), rects, bar, 8)
          assert(type(pad) == "number" and pad >= 8 and pad <= 40,
                 "junk '" .. junk .. "' gave " .. tostring(pad))
        end

        eq(dot.padding(on("1:1481,3,28,28"), rects, bar, 50), 50, "a larger resting padding is kept")
        eq(dot.padding({ RECORDING = "off" }, rects, bar, 50), 50, "and off returns to it")
        """)
        #expect(error == nil, "\(error ?? "")")
    }

    /// An engine from before RECORDING_FRAMES reports one frame in desktop
    /// coordinates, for whichever display came first. Only its on/off is
    /// believed.
    @Test func anOlderEngineGetsTheStandardRoom() throws {
        let error = try runDot("""
        for _, x in ipairs({ "-22", "1481", "184", "abc" }) do
          eq(dot.padding({ RECORDING = "on", RECORDING_X = x }, rects, bar, 8), 18, "x = " .. x)
          eq(dot.padding({ RECORDING = "on", RECORDING_X = x }, {}, bar, 8), 18, "no layout, x = " .. x)
        end
        eq(dot.padding({ RECORDING = "on" }, rects, bar, 24), 24, "a larger resting padding wins")
        eq(dot.padding({ RECORDING = "off", RECORDING_X = "-22" }, rects, bar, 8), 8, "off")
        """)
        #expect(error == nil, "\(error ?? "")")
    }

    /// bounding_rects are in bar points and the event in display points: a
    /// bar inset by its margin starts that far into the display.
    @Test func theBarMarginCounts() throws {
        let error = try runDot("""
        local inset = { topmost = "on", position = "top", margin = 10, y_offset = 6, height = 40 }
        -- The pill ends 8pt from the bar's right edge: 1484 in bar points,
        -- 1494 on the display, 13pt past the window's left edge at 1481.
        eq(dot.padding(on("1:1481,3,28,28"), { ["display-1"] = rect(1390, 94) }, inset, 4), 8, "margin 10")
        """)
        #expect(error == nil, "\(error ?? "")")
    }

    @Test func theClockIgnoresADotItsBarIsNotUnder() throws {
        let error = try runDot("""
        local frames = "1:1481,3,28,28 2:1081,-6,28,28"
        local function with(changes)
          local b = { topmost = "on", position = "top", margin = 0, y_offset = 0, height = 40 }
          for k, v in pairs(changes) do b[k] = v end
          return b
        end
        for what, b in pairs({
          ["topmost off"] = with({ topmost = "off" }),
          ["topmost window"] = with({ topmost = "window" }),
          ["a bottom bar"] = with({ position = "bottom" }),
          ["a bar below the dot"] = with({ y_offset = 40 }),
        }) do
          eq(dot.padding(on(frames), rects, b, 8), 8, what)
          if what ~= "a bar below the dot" then
            eq(dot.padding({ RECORDING = "on", RECORDING_X = "1481" }, rects, b, 8), 8, what .. " (older engine)")
          end
        end
        eq(dot.padding(on(frames), rects, nil, 8), 8, "no bar")
        assert(dot.covers_menu_bar(bar) and not dot.covers_menu_bar(nil))
        """)
        #expect(error == nil, "\(error ?? "")")
    }

    /// Bars that were only just built have laid nothing out yet. Guessing
    /// then is how a wrong edge gets measured; nil says "ask again".
    @Test func theClockWaitsForLayoutInsteadOfGuessing() throws {
        let error = try runDot("""
        eq(dot.padding(on("1:1481,3,28,28"), {}, bar, 8), nil, "no rects")
        eq(dot.padding(on("1:1481,3,28,28"), nil, bar, 8), nil, "nil rects")
        """)
        #expect(error == nil, "\(error ?? "")")
    }

    /// The clock must go through the helper: the desktop-wide scalar and the
    /// "display 1, or whichever rect comes first" fallback ARE the bug.
    @Test func theClockRoutesTheDotThroughTheHelper() throws {
        let source = try String(
            contentsOf: Self.portRoot.appendingPathComponent("items/calendar.lua"), encoding: .utf8)
        #expect(source.contains("recording_dot.padding("))
        #expect(!source.contains("RECORDING_X"))
        #expect(!source.contains(#"rect["display-1"]"#))
    }
}
