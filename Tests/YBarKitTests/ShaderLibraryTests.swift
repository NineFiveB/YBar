import Metal
import Testing
@testable import YBarKit

/// The shader ships as source and is compiled on the user's machine by
/// Renderer.init (Package.swift copies YBar.metal verbatim so a CLT-only
/// build needs no metal toolchain), so a typo in it is a daemon that fails to
/// start rather than a build error. Compile it here the way the renderer
/// does, and check that every entry point the pipelines are built from is
/// still there. Skipped where there is no Metal device at all.
@Suite struct ShaderLibraryTests {
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a Metal device"))
    func shaderSourceCompilesWithEveryEntryPoint() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let source = try #require(Renderer.shaderSource())
        let library = try device.makeLibrary(source: source, options: nil)
        for name in ["quad_vertex", "quad_fragment", "shape_vertex", "shape_fragment",
                     "glyph_vertex", "glyph_fragment"] {
            #expect(library.makeFunction(name: name) != nil, "missing entry point \(name)")
        }
    }
}
