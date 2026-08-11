// GPU ABI stride checks — kept as runtime tests as well as static_asserts so
// a compiler/packing regression names itself in CI output (spec 7.3).

#include <catch2/catch_test_macros.hpp>

#include "render/instances.h"

using namespace ybar::render;

TEST_CASE("instance strides match the shader ABI") {
    CHECK(sizeof(QuadInstance) == 112);
    CHECK(sizeof(GlyphInstance) == 64);
    CHECK(sizeof(ShapeVertex) == 32);
    CHECK(sizeof(Hole) == 32);
    CHECK(sizeof(Uniforms) == 16);
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
