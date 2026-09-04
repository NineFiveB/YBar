// GPU ABI stride checks — kept as runtime tests as well as static_asserts so
// a compiler/packing regression names itself in CI output (spec 7.3).

#include <cstddef>

#include <catch2/catch_test_macros.hpp>

#include "render/instances.h"

using namespace ybar::render;

TEST_CASE("instance strides match the shader ABI") {
    CHECK(sizeof(QuadInstance) == 112);
    CHECK(sizeof(GlyphInstance) == 64);
    CHECK(sizeof(ShapeVertex) == 32);
    CHECK(sizeof(Hole) == 32);
    // 32, not the reference's 16: Uniforms gained the pointer position that
    // drives the pointer-tracked key light (Windows-only, see WINDOWS-PORT
    // §7.3). It is a per-frame constant buffer, NOT the shared per-item
    // instance ABI — the four strides above are the ones that must stay
    // byte-identical with Instances.swift, and they do.
    CHECK(sizeof(Uniforms) == 32);
}

TEST_CASE("field offsets match the shader struct layout") {
    CHECK(offsetof(QuadInstance, radii) == 16);
    CHECK(offsetof(QuadInstance, fill) == 32);
    CHECK(offsetof(QuadInstance, gradientDir) == 64);
    CHECK(offsetof(QuadInstance, borderWidth) == 72);
    CHECK(offsetof(QuadInstance, cornerExponent) == 76);
    CHECK(offsetof(QuadInstance, borderColor) == 80);
    CHECK(offsetof(QuadInstance, flags) == 96);

    CHECK(offsetof(GlyphInstance, uvOrigin) == 16);
    CHECK(offsetof(GlyphInstance, color) == 32);
    CHECK(offsetof(GlyphInstance, flags) == 48);

    CHECK(offsetof(Hole, radius) == 16);
}
