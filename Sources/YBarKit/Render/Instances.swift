import simd

// GPU instance layouts. These must match the structs in Shaders/YBar.metal exactly
// (verified by the stride assertions below, called from Renderer.init).

/// One SDF quad: rounded/squircle rect with fill, optional 2-stop gradient, border.
/// All coordinates are in device pixels, top-left origin.
public struct QuadInstance {
    public var origin: SIMD2<Float>
    public var size: SIMD2<Float>
    /// Per-corner radii: (topLeft, topRight, bottomRight, bottomLeft).
    public var radii: SIMD4<Float>
    /// Straight-alpha sRGB fill color (shader premultiplies).
    public var fill: SIMD4<Float>
    /// Second gradient stop (used when flags bit 0 is set).
    public var fill2: SIMD4<Float>
    /// Unit direction of the gradient axis.
    public var gradientDir: SIMD2<Float>
    public var borderWidth: Float
    /// Superellipse exponent: 2 = circular corner, ~4.5 ≈ continuous. (Reserved; v1 shader uses circular.)
    public var cornerExponent: Float
    public var borderColor: SIMD4<Float>
    public var flags: UInt32
    // Scalar padding (SIMD3 has 16-byte alignment and would desync the layouts).
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0

    public static let flagGradient: UInt32 = 1 << 0

    public init(
        origin: SIMD2<Float>, size: SIMD2<Float>, radii: SIMD4<Float>,
        fill: SIMD4<Float>, fill2: SIMD4<Float> = .zero, gradientDir: SIMD2<Float> = SIMD2(0, 1),
        borderWidth: Float = 0, cornerExponent: Float = 2,
        borderColor: SIMD4<Float> = .zero, flags: UInt32 = 0
    ) {
        self.origin = origin
        self.size = size
        self.radii = radii
        self.fill = fill
        self.fill2 = fill2
        self.gradientDir = gradientDir
        self.borderWidth = borderWidth
        self.cornerExponent = cornerExponent
        self.borderColor = borderColor
        self.flags = flags
    }
}

/// One glyph (or symbol/emoji) quad sampling an atlas page.
/// Coordinates in device pixels; UVs normalized to the atlas texture.
public struct GlyphInstance {
    public var origin: SIMD2<Float>
    public var size: SIMD2<Float>
    public var uvOrigin: SIMD2<Float>
    public var uvSize: SIMD2<Float>
    /// Tint for mask glyphs; ignored for color glyphs except alpha.
    public var color: SIMD4<Float>
    public var flags: UInt32
    var _pad0: UInt32 = 0
    var _pad1: UInt32 = 0
    var _pad2: UInt32 = 0

    /// Set when the glyph lives in the color (BGRA) atlas page rather than the mask page.
    public static let flagColorGlyph: UInt32 = 1 << 0

    public init(
        origin: SIMD2<Float>, size: SIMD2<Float>,
        uvOrigin: SIMD2<Float>, uvSize: SIMD2<Float>,
        color: SIMD4<Float>, flags: UInt32 = 0
    ) {
        self.origin = origin
        self.size = size
        self.uvOrigin = uvOrigin
        self.uvSize = uvSize
        self.color = color
        self.flags = flags
    }
}

/// Raw colored triangle vertex for CPU-tessellated shapes (graph fills/lines).
public struct ShapeVertex {
    public var position: SIMD2<Float>
    var _pad: SIMD2<Float> = .zero
    /// Straight-alpha linear color (shader premultiplies).
    public var color: SIMD4<Float>

    public init(position: SIMD2<Float>, color: SIMD4<Float>) {
        self.position = position
        self.color = color
    }
}

public struct Uniforms {
    public var viewportSize: SIMD2<Float>

    public init(viewportSize: SIMD2<Float>) {
        self.viewportSize = viewportSize
    }
}

/// The flat, paint-ordered output of a scene build: everything the GPU needs
/// for one frame of one bar, in device pixels.
public struct DisplayList {
    public var quads: [QuadInstance] = []
    /// Triangles drawn between quads and glyphs (graph fills/lines).
    public var triangles: [ShapeVertex] = []
    public var glyphs: [GlyphInstance] = []

    public init() {}

    public var isEmpty: Bool { quads.isEmpty && triangles.isEmpty && glyphs.isEmpty }
}

enum InstanceLayout {
    /// Strides expected by the Metal-side structs; asserted at renderer init.
    static let quadStride = 112
    static let glyphStride = 64
    static let shapeStride = 32

    static func validate() {
        assert(MemoryLayout<QuadInstance>.stride == quadStride,
               "QuadInstance stride \(MemoryLayout<QuadInstance>.stride) != Metal \(quadStride)")
        assert(MemoryLayout<GlyphInstance>.stride == glyphStride,
               "GlyphInstance stride \(MemoryLayout<GlyphInstance>.stride) != Metal \(glyphStride)")
        assert(MemoryLayout<ShapeVertex>.stride == shapeStride,
               "ShapeVertex stride \(MemoryLayout<ShapeVertex>.stride) != Metal \(shapeStride)")
    }
}
