// Glyph clip UV-remap tests (spec 3.9, 14). Fixed-width slots clip glyph
// quads geometrically and remap the atlas UVs proportionally — no scissor or
// stencil — so a wrong remap shows as smeared or shifted texels, not a crash.
// These pin the exact math headlessly.

#include <catch2/catch_test_macros.hpp>

#include "render/scene_builder.h"

using namespace ybar::render;

namespace {

// A glyph quad spanning [10,18] x [20,24] device px whose atlas cell spans
// UV [0.25,0.375] x [0.5,0.5625]. Texel density per axis:
//   uScale = 0.125 / 8 = 0.015625 UV/px, vScale = 0.0625 / 4 = 0.015625.
// Every value is dyadic so all expected remaps below are float-exact.
GlyphInstance makeGlyph() {
    GlyphInstance glyph;
    glyph.origin = {10, 20};
    glyph.size = {8, 4};
    glyph.uvOrigin = {0.25f, 0.5f};
    glyph.uvSize = {0.125f, 0.0625f};
    glyph.color = {1, 0, 0, 1};
    glyph.flags = kGlyphFlagColor;
    return glyph;
}

} // namespace

TEST_CASE("a glyph fully inside the clip box is untouched") {
    GlyphInstance glyph = makeGlyph();
    REQUIRE(clipGlyph(glyph, {0, 0}, {100, 100}));
    CHECK(glyph.origin.x == 10);
    CHECK(glyph.origin.y == 20);
    CHECK(glyph.size.x == 8);
    CHECK(glyph.size.y == 4);
    CHECK(glyph.uvOrigin.x == 0.25f);
    CHECK(glyph.uvOrigin.y == 0.5f);
    CHECK(glyph.uvSize.x == 0.125f);
    CHECK(glyph.uvSize.y == 0.0625f);
}

TEST_CASE("a glyph fully outside the clip box is culled") {
    // false = the caller drops the instance (never pushed to the list).
    GlyphInstance right = makeGlyph();
    CHECK_FALSE(clipGlyph(right, {30, 0}, {40, 100})); // box left of clip
    GlyphInstance left = makeGlyph();
    CHECK_FALSE(clipGlyph(left, {0, 0}, {5, 100})); // box right of clip
    GlyphInstance below = makeGlyph();
    CHECK_FALSE(clipGlyph(below, {0, 30}, {100, 40})); // box above clip
    GlyphInstance above = makeGlyph();
    CHECK_FALSE(clipGlyph(above, {0, 0}, {100, 15})); // box below clip
    // A shared edge covers no pixels: clip ends exactly at the glyph's left.
    GlyphInstance touching = makeGlyph();
    CHECK_FALSE(clipGlyph(touching, {0, 0}, {10, 100}));
}

TEST_CASE("left-edge clip remaps origin and UVs proportionally") {
    GlyphInstance glyph = makeGlyph();
    REQUIRE(clipGlyph(glyph, {12, 0}, {100, 100}));
    CHECK(glyph.origin.x == 12);
    CHECK(glyph.origin.y == 20);
    CHECK(glyph.size.x == 6); // 18 - 12
    CHECK(glyph.size.y == 4);
    CHECK(glyph.uvOrigin.x == 0.28125f); // 0.25 + (12-10) * 0.015625
    CHECK(glyph.uvOrigin.y == 0.5f);
    CHECK(glyph.uvSize.x == 0.09375f); // 6 * 0.015625
    CHECK(glyph.uvSize.y == 0.0625f);  // 4 * 0.015625, unchanged
    // Clipping is geometry-only: tint and flags pass through.
    CHECK(glyph.flags == kGlyphFlagColor);
    CHECK(glyph.color.x == 1);
}

TEST_CASE("right-edge clip shrinks uvSize and keeps uvOrigin") {
    GlyphInstance glyph = makeGlyph();
    REQUIRE(clipGlyph(glyph, {0, 0}, {15, 100}));
    CHECK(glyph.origin.x == 10);
    CHECK(glyph.origin.y == 20);
    CHECK(glyph.size.x == 5); // 15 - 10
    CHECK(glyph.size.y == 4);
    CHECK(glyph.uvOrigin.x == 0.25f); // left edge kept
    CHECK(glyph.uvOrigin.y == 0.5f);
    CHECK(glyph.uvSize.x == 0.078125f); // 5 * 0.015625
    CHECK(glyph.uvSize.y == 0.0625f);
}

TEST_CASE("top-edge clip remaps origin and UVs proportionally") {
    GlyphInstance glyph = makeGlyph();
    REQUIRE(clipGlyph(glyph, {0, 21}, {100, 100}));
    CHECK(glyph.origin.x == 10);
    CHECK(glyph.origin.y == 21);
    CHECK(glyph.size.x == 8);
    CHECK(glyph.size.y == 3); // 24 - 21
    CHECK(glyph.uvOrigin.x == 0.25f);
    CHECK(glyph.uvOrigin.y == 0.515625f); // 0.5 + (21-20) * 0.015625
    CHECK(glyph.uvSize.x == 0.125f);
    CHECK(glyph.uvSize.y == 0.046875f); // 3 * 0.015625
}

TEST_CASE("bottom-edge clip shrinks uvSize and keeps uvOrigin") {
    GlyphInstance glyph = makeGlyph();
    REQUIRE(clipGlyph(glyph, {0, 0}, {100, 22}));
    CHECK(glyph.origin.x == 10);
    CHECK(glyph.origin.y == 20);
    CHECK(glyph.size.x == 8);
    CHECK(glyph.size.y == 2); // 22 - 20
    CHECK(glyph.uvOrigin.x == 0.25f); // top edge kept
    CHECK(glyph.uvOrigin.y == 0.5f);
    CHECK(glyph.uvSize.x == 0.125f);
    CHECK(glyph.uvSize.y == 0.03125f); // 2 * 0.015625
}

TEST_CASE("corner clip remaps both axes at once") {
    GlyphInstance glyph = makeGlyph();
    REQUIRE(clipGlyph(glyph, {12, 21}, {15, 22}));
    CHECK(glyph.origin.x == 12);
    CHECK(glyph.origin.y == 21);
    CHECK(glyph.size.x == 3); // 15 - 12
    CHECK(glyph.size.y == 1); // 22 - 21
    CHECK(glyph.uvOrigin.x == 0.28125f);  // 0.25 + 2 * 0.015625
    CHECK(glyph.uvOrigin.y == 0.515625f); // 0.5 + 1 * 0.015625
    CHECK(glyph.uvSize.x == 0.046875f); // 3 * 0.015625
    CHECK(glyph.uvSize.y == 0.015625f); // 1 * 0.015625
}

TEST_CASE("a degenerate clip box culls everything") {
    // Zero-width and zero-height boxes intersect no pixels, even when the
    // shared line lies inside the glyph.
    GlyphInstance zeroWidth = makeGlyph();
    CHECK_FALSE(clipGlyph(zeroWidth, {12, 0}, {12, 100}));
    GlyphInstance zeroHeight = makeGlyph();
    CHECK_FALSE(clipGlyph(zeroHeight, {0, 21}, {100, 21}));
    GlyphInstance inverted = makeGlyph();
    CHECK_FALSE(clipGlyph(inverted, {15, 0}, {12, 100}));
}
