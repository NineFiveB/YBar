import Foundation
import Testing
@testable import YBarKit

/// `--bar refraction` decides where the glass rim reads its backdrop from,
/// and the one thing that must never drift is which value is allowed to ask
/// for Screen Recording. `screen` asks because someone typed it; `auto` takes
/// what is already granted and asks for nothing; `off` is the default.
@MainActor
@Suite struct RefractionTests {
    @Test func everyModeRoundTripsThroughItsToken() {
        for mode in RefractionMode.allCases {
            #expect(RefractionMode(rawValue: mode.rawValue) == mode)
        }
        #expect(RefractionMode(rawValue: "off") == .off)
        #expect(RefractionMode(rawValue: "auto") == .auto)
        #expect(RefractionMode(rawValue: "screen") == .screen)
        #expect(RefractionMode(rawValue: "wallpaper") == .wallpaper)
        #expect(RefractionMode(rawValue: "Screen") == nil)
        #expect(RefractionMode(rawValue: "on") == nil)
    }

    /// Nothing captures and nothing prompts unless a config says so.
    @Test func theDefaultIsOff() {
        #expect(BarSettings().refraction == .off)
    }

    /// The lens is per FRAME, not per item: the flag rides along only while
    /// the renderer holds a backdrop for the surface being drawn. A glass
    /// plate built without one must come out clean, or the shader would sample
    /// a texture that is not bound.
    @Test func onlyAFrameWithABackdropCarriesTheLens() {
        var background = BackgroundStyle()
        background.drawing = true
        background.glass = true
        background.color = YColor(argb: 0x2020_2020)
        background.cornerRadius = 14
        let rect = CGRect(x: 0, y: 0, width: 60, height: 28)

        let builder = HeadlessScene().builder
        let without = builder.backgroundQuad(background, rect: rect, scale: 2, refract: false)
        #expect(without.flags & QuadInstance.flagGlass != 0)
        #expect(without.flags & QuadInstance.flagRefract == 0)

        let with = builder.backgroundQuad(background, rect: rect, scale: 2, refract: true)
        #expect(with.flags & QuadInstance.flagRefract != 0)
    }

    /// A plate with no glass gets no lens either, whatever the frame says:
    /// refraction is an edge effect on a material, and a flat fill has none.
    @Test func aPlateWithoutGlassNeverRefracts() {
        var background = BackgroundStyle()
        background.drawing = true
        background.glass = false
        background.color = YColor(argb: 0xFF20_2020)
        let quad = HeadlessScene().builder.backgroundQuad(
            background, rect: CGRect(x: 0, y: 0, width: 40, height: 20),
            scale: 2, refract: true)
        #expect(quad.flags & QuadInstance.flagRefract == 0)
    }

    /// The tuned profile is what the shader reads; zero strength is the signal
    /// that there is nothing to sample, so the two must stay distinguishable.
    @Test func zeroStrengthIsTheDisabledSignal() {
        #expect(BackdropParams().strength == 0)
        #expect(BackdropParams.tuned.strength > 0)
        // The lens must not reach across the body of a pill.
        #expect(BackdropParams.tuned.band < 14)
        // Split has to stay under the bend, or the edge reads as a colour
        // fringe rather than a displaced image.
        #expect(BackdropParams.tuned.dispersion < BackdropParams.tuned.strength)
    }
}
