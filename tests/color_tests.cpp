// Color pipeline contract tests (CoreTests.swift / ClippingTests.swift
// parity) — docs/WINDOWS-PORT.md section 3.3.

#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>

#include "model/color.h"

using namespace ybar::model;
using Catch::Matchers::WithinAbs;

TEST_CASE("parses 0xAARRGGBB hex, case-insensitive") {
    REQUIRE(Color::parse("0xffff0000"));
    CHECK(Color::parse("0xffff0000")->argb == 0xffff0000u);
    CHECK(Color::parse("0XFF00FF00")->argb == 0xff00ff00u);
    CHECK(Color::parse("0xdd1e1e2e")->argb == 0xdd1e1e2eu);
}

TEST_CASE("parses plain decimal u32") {
    REQUIRE(Color::parse("4278190080"));
    CHECK(Color::parse("4278190080")->argb == 0xff000000u);
    CHECK(Color::parse("0")->argb == 0u);
}

TEST_CASE("rejects everything else") {
    CHECK_FALSE(Color::parse("#ffffff"));
    CHECK_FALSE(Color::parse("red"));
    CHECK_FALSE(Color::parse(""));
    CHECK_FALSE(Color::parse("0x"));
    CHECK_FALSE(Color::parse("0x1ffffffff"));  // 9 digits
    CHECK_FALSE(Color::parse("4294967296"));   // u32 overflow
    CHECK_FALSE(Color::parse("0xghij"));
    CHECK_FALSE(Color::parse("12.5"));
}

TEST_CASE("serializes as lowercase 0x%08x") {
    CHECK(Color{0xFFAB12CDu}.hex() == "0xffab12cd");
    CHECK(Color{0x00000001u}.hex() == "0x00000001");
}

TEST_CASE("sRGB linearization matches the reference value") {
    // ClippingTests.swift: 0xFF808080 -> ~0.2158 linear per channel.
    CHECK_THAT(Color::toLinear(Color{0xff808080u}.r()), WithinAbs(0.2158, 0.001));
}

TEST_CASE("toGamma inverts toLinear across the channel range") {
    for (int v = 0; v <= 255; ++v) {
        const float srgb = static_cast<float>(v) / 255.0f;
        CHECK_THAT(Color::toGamma(Color::toLinear(srgb)), WithinAbs(srgb, 1e-4));
    }
}

TEST_CASE("lerp endpoints are exact and mid-lerp runs in linear light") {
    const Color red{0xffff0000u};
    const Color green{0xff00ff00u};
    CHECK(Color::lerp(red, green, 0.0f) == red);
    CHECK(Color::lerp(red, green, 1.0f) == green);

    // Linear-light midpoint of full red/green is ~0.5 linear per active
    // channel -> ~0xbc gamma-encoded, visibly brighter than the naive 0x80
    // per-byte midpoint (the sketchybar off-hue artifact YBar fixed).
    const Color mid = Color::lerp(red, green, 0.5f);
    CHECK(((mid.argb >> 16) & 0xff) > 0xb0);
    CHECK(((mid.argb >> 8) & 0xff) > 0xb0);
    CHECK((mid.argb >> 24) == 0xff);
}
