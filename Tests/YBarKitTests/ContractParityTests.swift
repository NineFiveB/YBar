import Foundation
import simd
import Testing
@testable import YBarKit

// Contracts the Windows port pins in glyph_clip_tests.cpp,
// item_store_tests.cpp, width_animation_tests.cpp, curves_tests.cpp and
// audit_regression_tests.cpp. Since docs/WINDOWS-PORT.md names the Swift
// tree as the behaviour authority, drift on this side is the unguarded
// direction; these suites pin it.

/// A glyph quad spanning [10,18] x [20,24] px whose atlas cell spans UV
/// [0.25,0.375] x [0.5,0.5625]: 0.015625 UV per px on both axes, so every
/// expected remap below is float-exact.
@MainActor
@Suite struct GlyphClipParityTests {
    private func clipped(_ clip: CGRect?) -> GlyphInstance? {
        let entry = GlyphAtlas.Entry(
            uvOrigin: SIMD2(0.25, 0.5), uvSize: SIMD2(0.125, 0.0625),
            sizePx: SIMD2(8, 4), bearingPx: SIMD2(0, 0), isColor: true)
        return SceneBuilder.glyphInstance(
            origin: SIMD2(10, 20), entry: entry, color: SIMD4(1, 0, 0, 1), clip: clip)
    }

    private func box(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) -> CGRect {
        CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    @Test func aGlyphFullyInsideTheClipBoxIsUntouched() throws {
        let glyph = try #require(clipped(box(0, 0, 100, 100)))
        #expect(glyph.origin == SIMD2(10, 20))
        #expect(glyph.size == SIMD2(8, 4))
        #expect(glyph.uvOrigin == SIMD2(0.25, 0.5))
        #expect(glyph.uvSize == SIMD2(0.125, 0.0625))
    }

    @Test func aGlyphFullyOutsideTheClipBoxIsCulled() {
        #expect(clipped(box(30, 0, 40, 100)) == nil)   // box right of the glyph
        #expect(clipped(box(0, 0, 5, 100)) == nil)     // box left of the glyph
        #expect(clipped(box(0, 30, 100, 40)) == nil)   // box below the glyph
        #expect(clipped(box(0, 0, 100, 15)) == nil)    // box above the glyph
        // A shared edge covers no pixels: the clip ends exactly at the glyph's left.
        #expect(clipped(box(0, 0, 10, 100)) == nil)
    }

    @Test func leftEdgeClipRemapsOriginAndUVsProportionally() throws {
        let glyph = try #require(clipped(box(12, 0, 100, 100)))
        #expect(glyph.origin == SIMD2(12, 20))
        #expect(glyph.size == SIMD2(6, 4))
        #expect(glyph.uvOrigin.x == 0.28125)  // 0.25 + 2 px * 0.015625
        #expect(glyph.uvOrigin.y == 0.5)
        #expect(glyph.uvSize.x == 0.09375)    // 6 px * 0.015625
        #expect(glyph.uvSize.y == 0.0625)
        // Clipping is geometry only: tint and the colour-page flag pass through.
        #expect(glyph.color == SIMD4(1, 0, 0, 1))
        #expect(glyph.flags & GlyphInstance.flagColorGlyph != 0)
    }

    @Test func rightEdgeClipShrinksUVSizeAndKeepsUVOrigin() throws {
        let glyph = try #require(clipped(box(0, 0, 15, 100)))
        #expect(glyph.origin == SIMD2(10, 20))
        #expect(glyph.size == SIMD2(5, 4))
        #expect(glyph.uvOrigin == SIMD2(0.25, 0.5))
        #expect(glyph.uvSize == SIMD2(0.078125, 0.0625))
    }

    @Test func topEdgeClipRemapsOriginAndUVsProportionally() throws {
        let glyph = try #require(clipped(box(0, 21, 100, 100)))
        #expect(glyph.origin == SIMD2(10, 21))
        #expect(glyph.size == SIMD2(8, 3))
        #expect(glyph.uvOrigin == SIMD2(0.25, 0.515625))  // 0.5 + 1 px * 0.015625
        #expect(glyph.uvSize == SIMD2(0.125, 0.046875))
    }

    @Test func bottomEdgeClipShrinksUVSizeAndKeepsUVOrigin() throws {
        let glyph = try #require(clipped(box(0, 0, 100, 22)))
        #expect(glyph.origin == SIMD2(10, 20))
        #expect(glyph.size == SIMD2(8, 2))
        #expect(glyph.uvOrigin == SIMD2(0.25, 0.5))
        #expect(glyph.uvSize == SIMD2(0.125, 0.03125))
    }

    @Test func cornerClipRemapsBothAxesAtOnce() throws {
        let glyph = try #require(clipped(box(12, 21, 15, 22)))
        #expect(glyph.origin == SIMD2(12, 21))
        #expect(glyph.size == SIMD2(3, 1))
        #expect(glyph.uvOrigin == SIMD2(0.28125, 0.515625))
        #expect(glyph.uvSize == SIMD2(0.046875, 0.015625))
    }
}

@MainActor
@Suite struct ItemStoreVerbTests {
    private func names(_ store: ItemStore) -> [String] { store.items.map(\.name) }

    @Test func moveBeforeAndAfterAnAnchor() {
        let store = ItemStore()
        for name in ["a", "b", "c"] { store.add(name: name, position: .left) }
        #expect(store.move(name: "c", anchor: "a", before: true))
        #expect(names(store) == ["c", "a", "b"])
        #expect(store.move(name: "c", anchor: "b", before: false))
        #expect(names(store) == ["a", "b", "c"])
        #expect(!store.move(name: "a", anchor: "a", before: true))        // self anchor
        #expect(!store.move(name: "a", anchor: "missing", before: true))  // missing anchor is a no-op
        #expect(names(store) == ["a", "b", "c"])
    }

    @Test func reorderSwapsListedItemsIntoEachOthersSlots() {
        let store = ItemStore()
        for name in ["a", "b", "c", "d"] { store.add(name: name, position: .left) }
        #expect(store.reorder(names: ["c", "a"]))  // slots {0,2} filled in the given order
        #expect(names(store) == ["c", "b", "a", "d"])
        // Unknown names are dropped and the listed items still take their
        // slots (the port refuses the whole list here); duplicates fail.
        #expect(store.reorder(names: ["a", "missing"]))
        #expect(!store.reorder(names: ["a", "a"]))
        #expect(names(store) == ["c", "b", "a", "d"])
    }

    @Test func renameFixesBracketMembersAndPopupHosts() throws {
        let store = ItemStore()
        store.add(name: "volume", position: .right)
        let bracket = try #require(store.add(name: "widgets", position: .right))
        bracket.kind = .bracket
        bracket.members = ["volume", "battery"]
        let member = try #require(store.add(name: "volume.popup.row", position: .popup))
        member.popupHost = "volume"

        #expect(store.rename(from: "volume", to: "audio"))
        #expect(store.item(named: "audio") != nil)
        #expect(store.item(named: "volume") == nil)
        #expect(bracket.members == ["audio", "battery"])
        #expect(member.popupHost == "audio")

        #expect(!store.rename(from: "missing", to: "x"))
        store.add(name: "taken", position: .left)
        #expect(!store.rename(from: "audio", to: "taken"))
    }

    @Test func cloneCopiesValueFieldsButNeverComponentsOrKind() throws {
        let store = ItemStore()
        let context = PropertyContext(scheduler: AnimationScheduler(), invalidate: {})
        let source = try #require(store.add(name: "src", position: .left))
        source.kind = .bracket
        #expect(PropertySetter.set(item: source, property: "label", value: "text", context: context) == nil)
        #expect(PropertySetter.set(item: source, property: "width", value: "50", context: context) == nil)
        source.graph = GraphState(capacity: 4)
        source.members = ["m1"]

        let copy = try #require(store.clone(source: "src", as: "copy"))
        #expect(copy.label.string == "text")
        #expect(copy.customWidth == 50)
        #expect(copy.members == ["m1"])
        #expect(copy.graph == nil)       // components are deliberately not copied
        #expect(copy.kind == .item)      // clones go through add()
        #expect(names(store) == ["src", "copy"])
        #expect(store.clone(source: "src", as: "copy") == nil)      // taken
        #expect(store.clone(source: "missing", as: "other") == nil)
    }

    @Test func regexTargetsMatchUnanchoredSubstrings() {
        let store = ItemStore()
        for name in ["bt.device.airpods", "bt.device.keyboard", "volume"] {
            store.add(name: name, position: .left)
        }
        #expect(store.items(matching: "/bt.device\\..*/").count == 2)
        // Unanchored: a mid-name fragment matches too (regexec parity).
        #expect(store.items(matching: "/device/").count == 2)
        #expect(store.items(matching: "volume").count == 1)
        #expect(store.items(matching: "missing").isEmpty)
        #expect(store.items(matching: "/[invalid/").isEmpty)  // a bad regex matches nothing
        #expect(store.expandMembers(["/device/", "bt.device.airpods", "volume"]).count == 3)  // deduplicated
    }

    @Test func itemsAtAPositionKeepRegistrationOrder() {
        let store = ItemStore()
        store.add(name: "r1", position: .right)
        store.add(name: "l1", position: .left)
        store.add(name: "r2", position: .right)
        #expect(store.items(at: .right).map(\.name) == ["r1", "r2"])
        #expect(store.items(at: .center).isEmpty)
        store.removeAll()
        #expect(store.items.isEmpty)
    }
}

/// `width=dynamic` under `--animate` (the sentinel resolution the port pins
/// in width_animation_tests.cpp), driven through the scheduler seam.
@MainActor
@Suite struct WidthDynamicAnimationTests {
    private func context(scheduler: AnimationScheduler, measured: Float,
                         frames: Int? = nil) -> PropertyContext {
        var context = PropertyContext(
            scheduler: scheduler, invalidate: {},
            measureNaturalWidth: { _ in measured },
            measureTextNaturalWidth: { _, _ in measured })
        if let frames { context.animation = (curve: .linear, durationFrames: frames) }
        return context
    }

    @Test func dynamicAnimatesToTheMeasuredWidthThenRestoresTheSentinel() {
        let scheduler = AnimationScheduler()
        let item = Item(name: "w", position: .left)
        item.customWidth = 40
        #expect(PropertySetter.set(item: item, property: "width", value: "dynamic",
                                   context: context(scheduler: scheduler, measured: 100, frames: 60)) == nil)
        #expect(scheduler.isAnimating)
        scheduler.tick(now: 1000)
        scheduler.tick(now: 1000.5)
        // Mid-flight it holds a real number between the endpoints, never -1.
        #expect(item.customWidth > 40)
        #expect(item.customWidth < 100)
        // Completion hands the sentinel back so the item tracks content again.
        scheduler.tick(now: 1002)
        #expect(item.customWidth == -1)
        #expect(!scheduler.isAnimating)
    }

    @Test func aDirectSetCancelsAnInFlightWidthAnimation() {
        let scheduler = AnimationScheduler()
        let item = Item(name: "w", position: .left)
        item.customWidth = 40
        _ = PropertySetter.set(item: item, property: "width", value: "dynamic",
                               context: context(scheduler: scheduler, measured: 100, frames: 60))
        #expect(scheduler.isAnimating)
        #expect(PropertySetter.set(item: item, property: "width", value: "33",
                                   context: context(scheduler: scheduler, measured: 100)) == nil)
        #expect(item.customWidth == 33)
        #expect(!scheduler.isAnimating)
        scheduler.tick(now: 1000)
        scheduler.tick(now: 1100)
        #expect(item.customWidth == 33)  // the cancelled animation never lands
    }

    @Test func textPartWidthFollowsTheSameSentinelRules() {
        let scheduler = AnimationScheduler()
        let item = Item(name: "w", position: .left)
        item.label.customWidth = 40
        // Direct dynamic: the sentinel lands immediately.
        _ = PropertySetter.set(item: item, property: "label.width", value: "dynamic",
                               context: context(scheduler: scheduler, measured: 100))
        #expect(item.label.customWidth == -1)
        // Animated fixed -> dynamic: measured width mid-flight, sentinel at the end.
        item.label.customWidth = 40
        _ = PropertySetter.set(item: item, property: "label.width", value: "dynamic",
                               context: context(scheduler: scheduler, measured: 100, frames: 60))
        #expect(scheduler.isAnimating)
        scheduler.tick(now: 0)
        scheduler.tick(now: 0.5)
        #expect(item.label.customWidth > 40)
        #expect(item.label.customWidth < 100)
        scheduler.tick(now: 2)
        #expect(item.label.customWidth == -1)
    }

    @Test func fixedToFixedAnimatesBetweenTheTwoWidths() {
        let scheduler = AnimationScheduler()
        let item = Item(name: "w", position: .left)
        item.customWidth = 20
        _ = PropertySetter.set(item: item, property: "width", value: "200",
                               context: context(scheduler: scheduler, measured: 100, frames: 60))
        scheduler.tick(now: 0)
        scheduler.tick(now: 0.5)
        #expect(abs(item.customWidth - 110) < 0.5)
        scheduler.tick(now: 2)
        #expect(item.customWidth == 200)
    }
}

@Suite struct CurveContractTests {
    @Test func quadraticIsTSquared() {
        #expect(abs(AnimationCurve.quadratic.value(0.5) - 0.25) < 1e-9)
    }

    @Test func overshootExceedsOneMidFlight() {
        #expect(stride(from: 0.5, to: 1.0, by: 0.01).contains { AnimationCurve.overshoot.value($0) > 1 })
    }

    @Test func nonSpringyCurvesAreMonotonic() {
        for curve in [AnimationCurve.linear, .quadratic, .sin, .tanh, .exp, .circ] {
            var previous = curve.value(0)
            for t in stride(from: 0.01, through: 1.0, by: 0.01) {
                let current = curve.value(t)
                #expect(current >= previous - 1e-12, "curve \(curve) at \(t)")
                previous = current
            }
        }
    }

    @Test func everyNameParsesByItsFirstLetter() {
        let table: [(String, AnimationCurve)] = [
            ("linear", .linear), ("quadratic", .quadratic), ("q", .quadratic), ("sin", .sin),
            ("tanh", .tanh), ("exp", .exp), ("circ", .circ), ("bounce", .bounce), ("overshoot", .overshoot),
            ("zigzag", .linear), ("", .linear), ("Linear", .linear),
        ]
        for (name, expected) in table {
            #expect(AnimationCurve.parse(name) == expected, "\(name)")
        }
    }
}

/// Regression guards from the 2026-08 spec-compliance audit: behaviour the
/// reference already has, pinned so it stays the contract the port follows.
@MainActor
@Suite struct AuditPinTests {
    private let context = PropertyContext(scheduler: AnimationScheduler(), invalidate: {})

    @Test func alignAcceptsOnlyLCR() {
        let item = Item(name: "a", position: .left)
        #expect(PropertySetter.set(item: item, property: "align", value: "c", context: context) == nil)
        #expect(PropertySetter.set(item: item, property: "align", value: "x", context: context) == "[!] invalid align: x")
        #expect(PropertySetter.set(item: item, property: "label.align", value: "top", context: context)
                == "[!] invalid align: top")
        #expect(item.align == "c")  // unchanged by the rejected set
    }

    @Test func nonFiniteNumbersAreRejected() {
        let item = Item(name: "a", position: .left)
        #expect(PropertySetter.set(item: item, property: "padding_left", value: "inf", context: context)
                == "[!] invalid number: inf")
        #expect(PropertySetter.set(item: item, property: "y_offset", value: "nan", context: context)
                == "[!] invalid number: nan")
    }

    @Test func errorStringsNameTheirProperty() {
        let item = Item(name: "a", position: .left)
        #expect(PropertySetter.set(item: item, property: "update_freq", value: "x", context: context)
                == "[!] invalid update_freq: x")
        #expect(PropertySetter.set(item: item, property: "updates", value: "x", context: context)
                == "[!] invalid updates: x")
        #expect(PropertySetter.set(item: item, property: "label.max_chars", value: "x", context: context)
                == "[!] invalid max_chars: x")
        #expect(PropertySetter.set(item: item, property: "label.scroll_duration", value: "x", context: context)
                == "[!] invalid scroll_duration: x")
        #expect(PropertySetter.set(item: item, property: "background", value: "1", context: context)
                == "[!] background needs a sub-property")
    }

    @Test func displayListsDropEmptyComponents() {
        let item = Item(name: "a", position: .left)
        #expect(PropertySetter.set(item: item, property: "display", value: "1,2,", context: context) == nil)
        #expect(item.associatedDisplayMask == 0b11)
        #expect(PropertySetter.set(item: item, property: "display", value: "", context: context) == nil)
        #expect(item.associatedDisplayMask == 0)  // mask 0 = every display
        #expect(PropertySetter.set(item: item, property: "display", value: "0", context: context)
                == "[!] invalid display list: 0")
    }

    @Test func aFreshGraphIsPreFilledToCapacity() {
        let graph = GraphState(capacity: 8)
        #expect(graph.ordered().count == 8)
        graph.push(1)
        #expect(graph.ordered().count == 8)  // the ring stays full-width
        #expect(graph.ordered().last == 1)
    }
}
