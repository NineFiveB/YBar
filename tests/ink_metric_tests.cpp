// Text-metric parity tests (spec 3.9, 7.4, 14).
//
// The load-bearing contract is that widths measure tight glyph INK with the
// exact truncation `(int)(ink + 1.5)` — every padding and alignment in a
// ported config depends on it. DirectWrite has no single-call equivalent of
// CoreText's glyph-path bounds, so ybar-win accumulates per-glyph design
// metrics; these tests pin the accumulation and the formula independently of
// any installed font, so they run headlessly in CI.

#include <catch2/catch_test_macros.hpp>

#include "render/font_cache.h"

using namespace ybar::render;

TEST_CASE("the sketchybar width formula truncates ink + 1.5") {
    // Reference: width = CGFloat(Int(pathBounds.width + 1.5)).
    CHECK(inkWidthToLayoutWidth(0.0) == 1.0);
    CHECK(inkWidthToLayoutWidth(0.4) == 1.0);
    CHECK(inkWidthToLayoutWidth(0.5) == 2.0);   // 0.5 + 1.5 = 2.0
    CHECK(inkWidthToLayoutWidth(9.9) == 11.0);  // 11.4 -> 11
    CHECK(inkWidthToLayoutWidth(10.0) == 11.0); // 11.5 -> 11 (truncation!)
    CHECK(inkWidthToLayoutWidth(41.2) == 42.0);
    // Never negative, whatever the input.
    CHECK(inkWidthToLayoutWidth(-0.2) == 1.0);
}

TEST_CASE("ink union spans the outermost glyph edges") {
    // Two glyphs: pen 0 with ink [1,9], pen 10 with ink [10.5, 18].
    const InkBounds bounds = unionInk({
        {1.0, 9.0, -2.0, 8.0},
        {10.5, 18.0, 0.0, 6.0},
    });
    REQUIRE(bounds.hasInk);
    CHECK(bounds.minX == 1.0);
    CHECK(bounds.width == 17.0); // 18 - 1
    CHECK(bounds.minY == -2.0);  // deepest descender (y-up)
    CHECK(bounds.maxY == 8.0);   // tallest ascender
}

TEST_CASE("blank glyphs contribute no ink") {
    // A space has left == right; it must not widen the box or shift minX.
    const InkBounds bounds = unionInk({
        {5.0, 5.0, 0.0, 0.0},  // space at the start
        {8.0, 12.0, 0.0, 7.0}, // the only inked glyph
        {20.0, 20.0, 0.0, 0.0} // trailing space
    });
    REQUIRE(bounds.hasInk);
    CHECK(bounds.minX == 8.0);
    CHECK(bounds.width == 4.0); // trailing whitespace excluded, per ink model
}

TEST_CASE("an all-blank line reports no ink") {
    const InkBounds bounds = unionInk({{0.0, 0.0, 0.0, 0.0}, {6.0, 6.0, 0.0, 0.0}});
    CHECK_FALSE(bounds.hasInk);
    CHECK(bounds.width == 0.0);
}

TEST_CASE("empty input is safe") {
    const InkBounds bounds = unionInk({});
    CHECK_FALSE(bounds.hasInk);
    CHECK(bounds.width == 0.0);
    CHECK(bounds.minX == 0.0);
}

TEST_CASE("ink bounds drive ink-centering symmetry") {
    // A single glyph whose ink spans [0, 10] y-up centers at +5 from the
    // baseline: baseline = centerY + (inkMinY + inkMaxY)/2 (spec 3.9).
    const InkBounds bounds = unionInk({{0.0, 10.0, 0.0, 10.0}});
    const double baselineOffset = (bounds.minY + bounds.maxY) / 2;
    CHECK(baselineOffset == 5.0);
    // With that baseline, ink spans centerY-5 .. centerY+5 — centered.
    CHECK(baselineOffset - bounds.maxY == -5.0);
    CHECK(baselineOffset - bounds.minY == 5.0);
}
