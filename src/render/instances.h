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
};
static_assert(sizeof(Uniforms) == 16, "Uniforms ABI stride");

// Flat, paint-ordered frame content in DEVICE PIXELS (top-left origin).
// Draw order: all quads -> all shape triangles -> all glyphs (spec 3.9).
struct DisplayList {
    static constexpr std::size_t kMaxHoles = 16;

    std::vector<QuadInstance> quads;
    std::vector<ShapeVertex> shapeVertices;
    std::vector<GlyphInstance> glyphs;
    std::vector<Hole> holes;
    Float2 viewportSize;
    // A marquee is on screen: the caller keeps the frame clock running
    // (continuousDemand, spec 7.2).
    bool hasMarquee = false;

    bool empty() const { return quads.empty() && shapeVertices.empty() && glyphs.empty(); }
};

} // namespace ybar::render
