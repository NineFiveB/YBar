import Foundation
import Testing
@testable import YBarKit

/// The painted rim and the pointer specular are drawn on EVERY OS, layered
/// over the native material where there is one. They used to be suppressed on
/// macOS 26+ on the assumption the system glass supplied them; measured on a
/// plain dark wallpaper it does not — a floating bar has nothing behind it to
/// refract, so the edge is the only thing that reads as glass.
@MainActor
@Suite struct PaintedGlassTests {
    private func pill(glass: Bool, sheen: Bool) -> Item {
        let item = Item(name: "pill", position: .left)
        item.label.string = "CPU"
        item.background.drawing = true
        item.background.height = 28
        item.background.cornerRadius = 14
        item.background.color = YColor(argb: 0x2020_2020)
        item.background.glass = glass
        item.background.sheen = sheen
        return item
    }

    @Test func glassPillsCarryThePaintedRim() {
        let scene = HeadlessScene()
        let quads = scene.build([pill(glass: true, sheen: false)]).list.quads
        #expect(quads.contains { $0.flags & QuadInstance.flagGlass != 0 })
    }

    @Test func sheenPillsAskForTheSpecular() {
        let scene = HeadlessScene()
        let list = scene.build([pill(glass: true, sheen: true)]).list
        #expect(list.quads.contains { $0.flags & QuadInstance.flagSheen != 0 })
        #expect(list.hasSheen)
    }

    /// Neither is drawn for a plate that asked for neither.
    @Test func aPlainPlateIsUnlit() {
        let scene = HeadlessScene()
        let list = scene.build([pill(glass: false, sheen: false)]).list
        #expect(list.quads.allSatisfy { $0.flags & QuadInstance.flagGlass == 0 })
        #expect(list.quads.allSatisfy { $0.flags & QuadInstance.flagSheen == 0 })
        #expect(!list.hasSheen)
    }

    /// Where the system material sits under the plate, the painted pass is
    /// told so, and draws the edge only — no bottom shade, which under a real
    /// glass capsule reads as a drop shadow.
    @Test func aNativeBackdropSuppressesTheBodyModelling() {
        let scene = HeadlessScene()
        let quads = scene.build([pill(glass: true, sheen: true)]).list.quads
        let lit = quads.filter { $0.flags & QuadInstance.flagSheen != 0 }
        #expect(!lit.isEmpty)
        if !SceneBuilder.nativeGlassBackdrops {
            #expect(lit.allSatisfy { $0.flags & QuadInstance.flagNativeGlass == 0 })
        }
    }

    /// A bracket with no fill of its own is structure, not glass: it groups
    /// members and must not claim a system backdrop it never got. BarManager
    /// only builds one when the fill alpha clears 0.02, so a transparent
    /// plate that claimed one drew a second lit capsule around the real pill.
    @Test func anEmptyPlateClaimsNoMaterial() {
        let scene = HeadlessScene()
        let hollow = pill(glass: true, sheen: true)
        hollow.background.color = YColor(argb: 0x0000_0000)
        let quads = scene.build([hollow]).list.quads
        #expect(quads.allSatisfy { $0.flags & QuadInstance.flagNativeGlass == 0 })
    }

    /// A plate that does carry a fill still claims it, on this OS.
    @Test func aFilledGlassPlateClaimsItsMaterial() {
        let scene = HeadlessScene()
        let quads = scene.build([pill(glass: true, sheen: true)]).list.quads
        let lit = quads.filter { $0.flags & QuadInstance.flagSheen != 0 }
        #expect(!lit.isEmpty)
        if SceneBuilder.nativeGlassBackdrops {
            #expect(lit.contains { $0.flags & QuadInstance.flagNativeGlass != 0 })
        }
    }

    /// The specular must not pin the frame clock: it repaints on pointer
    /// movement, not every frame.
    @Test func sheenAloneDoesNotDemandContinuousFrames() {
        let scene = HeadlessScene()
        let list = scene.build([pill(glass: true, sheen: true)]).list
        #expect(list.hasSheen)
        #expect(!list.needsContinuousFrames)
    }
}
