import Testing
@testable import YBarKit

/// The GPU instance ABI (review finding F6): Instances.swift and
/// Shaders/YBar.metal must stay byte-identical, and the Windows port pins
/// the same strides and offsets from its side (instances_tests.cpp). The
/// old check was a debug-only assert inside Renderer.init, elided by the
/// release build brew ships; these run under `make test`, and the renderer
/// now throws instead of trapping.
@Suite struct InstanceLayoutTests {
    @Test func stridesMatchTheShaderStructs() {
        #expect(MemoryLayout<QuadInstance>.stride == 112)
        #expect(MemoryLayout<GlyphInstance>.stride == 64)
        #expect(MemoryLayout<ShapeVertex>.stride == 32)
        // 48, not the Windows port's 32: the Metal Hole pads with a float3,
        // which is 16-byte aligned on both sides of the buffer.
        #expect(MemoryLayout<HoleInstance>.stride == 48)
        #expect(MemoryLayout<Uniforms>.stride == 24)
        // Fragment buffer 3, four floats. Its Metal twin is BackdropParams.
        #expect(MemoryLayout<BackdropParams>.stride == 16)
        #expect(InstanceLayout.mismatch() == nil)
    }

    @Test func quadFieldOffsetsMatchTheShaderStruct() {
        #expect(MemoryLayout<QuadInstance>.offset(of: \.origin) == 0)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.size) == 8)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.radii) == 16)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.fill) == 32)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.fill2) == 48)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.gradientDir) == 64)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.borderWidth) == 72)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.cornerExponent) == 76)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.borderColor) == 80)
        #expect(MemoryLayout<QuadInstance>.offset(of: \.flags) == 96)
    }

    @Test func glyphShapeAndHoleOffsetsMatchTheShaderStructs() {
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.origin) == 0)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.size) == 8)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.uvOrigin) == 16)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.uvSize) == 24)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.color) == 32)
        #expect(MemoryLayout<GlyphInstance>.offset(of: \.flags) == 48)
        #expect(MemoryLayout<ShapeVertex>.offset(of: \.position) == 0)
        #expect(MemoryLayout<ShapeVertex>.offset(of: \.color) == 16)
        #expect(MemoryLayout<HoleInstance>.offset(of: \.origin) == 0)
        #expect(MemoryLayout<HoleInstance>.offset(of: \.size) == 8)
        #expect(MemoryLayout<HoleInstance>.offset(of: \.radius) == 16)
        #expect(MemoryLayout<HoleInstance>.offset(of: \._pad) == 32)
        // Uniforms: the pad after holeCount keeps the pointer at 16.
        #expect(MemoryLayout<Uniforms>.offset(of: \.holeCount) == 8)
        #expect(MemoryLayout<Uniforms>.offset(of: \.pointer) == 16)
    }

    /// The flag bits are ABI too. Bits 0-4 are shared with the Windows port,
    /// which sets the same ones; the higher bits are macOS-only and the port
    /// must not reuse them. Bit 6 held the open-popup highlight that fed the
    /// pointer-following specular; it was freed when the specular went and is
    /// now the backdrop lens (`--bar refraction`). Bit 7 marks a plate with a
    /// system glass backdrop under it. Both are macOS-only — the port leaves
    /// them clear, which is why they sit at the top of the word.
    @Test func flagBitsMatchThePort() {
        #expect(QuadInstance.flagGradient == 1)
        #expect(QuadInstance.flagGlass == 2)
        #expect(QuadInstance.flagArc == 4)
        #expect(QuadInstance.flagHoles == 8)
        #expect(QuadInstance.flagShadow == 16)
        #expect(QuadInstance.flagSheen == 32)
        #expect(QuadInstance.flagRefract == 64)
        #expect(QuadInstance.flagNativeGlass == 128)
        #expect(GlyphInstance.flagColorGlyph == 1)
        #expect(GlyphInstance.flagDesaturate == 2)
    }
}
