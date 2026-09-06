// GPU instance ABI — byte-identical with shaders/ybar.hlsl and the YBar
// reference (Instances.swift): QuadInstance 112 B, GlyphInstance 64 B,
// ShapeVertex 32 B, Hole 32 B. The pads are ABI, not convenience.

#pragma once

#include <cstdint>
#include <vector>

namespace ybar::render {

struct alignas(4) Float2 {
    float x = 0;
    float y = 0;
};

struct alignas(4) Float4 {
    float x = 0;
    float y = 0;
    float z = 0;
    float w = 0;
};

inline constexpr std::uint32_t kQuadFlagGradient = 1u << 0;
inline constexpr std::uint32_t kQuadFlagGlass = 1u << 1;
inline constexpr std::uint32_t kQuadFlagArc = 1u << 2;
inline constexpr std::uint32_t kQuadFlagHoles = 1u << 3;
// Soft falloff quad (drop shadow, or a glow when the colour is light). The
// quad is drawn EXPANDED by the blur radius so the falloff has somewhere to
// live; the true shape's halfSize rides in fill2.xy and the blur radius in
// gradientDir.x, both of which a shadow quad otherwise leaves unused. Nothing
// about the 112-byte layout changes, so macOS stays byte-compatible and simply
// never sets this bit.
inline constexpr std::uint32_t kQuadFlagShadow = 1u << 4;
inline constexpr std::uint32_t kGlyphFlagColor = 1u << 0;
// Colour images only: render at luminance, for a disabled/pending row.
inline constexpr std::uint32_t kGlyphFlagDesaturate = 1u << 1;

struct QuadInstance {
    Float2 origin;
    Float2 size;
    Float4 radii;       // (topLeft, topRight, bottomRight, bottomLeft)
    Float4 fill;        // straight-alpha sRGB
    Float4 fill2;
    Float2 gradientDir;
    float borderWidth = 0;
    float cornerExponent = 2;
    Float4 borderColor;
    std::uint32_t flags = 0;
    std::uint32_t pad0 = 0;
    std::uint32_t pad1 = 0;
    std::uint32_t pad2 = 0;
};
static_assert(sizeof(QuadInstance) == 112, "QuadInstance ABI stride");

struct GlyphInstance {
    Float2 origin;
    Float2 size;
    Float2 uvOrigin;
    Float2 uvSize;
    Float4 color;
    std::uint32_t flags = 0;
    std::uint32_t pad0 = 0;
    std::uint32_t pad1 = 0;
    std::uint32_t pad2 = 0;
};
static_assert(sizeof(GlyphInstance) == 64, "GlyphInstance ABI stride");

struct ShapeVertex {
    Float2 position;
    Float2 pad;
    Float4 color; // straight-alpha (see reference comment discrepancy, spec 3.9)
};
static_assert(sizeof(ShapeVertex) == 32, "ShapeVertex ABI stride");

struct Hole {
    Float2 origin;
    Float2 size;
    float radius = 0;
    float pad0 = 0;
    float pad1 = 0;
    float pad2 = 0;
};
static_assert(sizeof(Hole) == 32, "Hole ABI stride");

struct Uniforms {
    Float2 viewportSize;
    std::uint32_t holeCount = 0;
    std::uint32_t pad = 0;
    // Pointer position in DEVICE PIXELS on the surface being drawn, or
    // negative when the pointer is not over it. Drives the pointer-tracked key
    // light in the glass branch. Unlike QuadInstance this is a per-frame
    // constant buffer, not the shared per-item instance ABI — growing it costs
    // macOS nothing until the Metal side chooses to mirror it, and a macOS
    // build that never writes the field simply gets the fixed light.
    Float2 pointer{-1.0f, -1.0f};
    Float2 pad2;
};
// cbuffers round to 16; 24 bytes of payload occupies 32.
static_assert(sizeof(Uniforms) == 32, "Uniforms ABI stride");

// A per-pill backdrop (spec 7.6): a wallpaper-material visual the window
// layer composes UNDER the swap chain, clipped to this rounded rect. CPU-side
// only, never uploaded, so it is outside the shared ABI. Device px, top-left
// origin, one radius for all four corners (the same limit as Hole, and the
// bar background carries a matching hole for every one of these).
struct Backdrop {
    Float2 origin;
    Float2 size;
    float radius = 0;
};

// Flat, paint-ordered frame content in DEVICE PIXELS (top-left origin).
// Draw order: all quads -> all shape triangles -> all glyphs (spec 3.9).
struct DisplayList {
    // Windows extension: the reference caps background.clip holes at 16.
    // Glass pills spend from the same budget here (one hole per backdrop),
    // and six widget brackets, the calendar and a focused workspace already
    // sit at eight;
    // the cap is CPU-side only (the hole buffer grows, the shader loops
    // holeCount), so it is raised rather than shared.
    static constexpr std::size_t kMaxHoles = 32;

    std::vector<QuadInstance> quads;
    std::vector<ShapeVertex> shapeVertices;
    std::vector<GlyphInstance> glyphs;
    std::vector<Hole> holes;
    std::vector<Backdrop> backdrops;
    Float2 viewportSize;
    // Device-px pointer position on this surface; negative = not over it.
    Float2 pointer{-1.0f, -1.0f};
    // A marquee is on screen: the caller keeps the frame clock running
    // (continuousDemand, spec 7.2).
    bool hasMarquee = false;

    bool empty() const { return quads.empty() && shapeVertices.empty() && glyphs.empty(); }
};

} // namespace ybar::render
