// FontSpec contract tests — docs/WINDOWS-PORT.md section 3.3.

#include <catch2/catch_test_macros.hpp>

#include "model/font_spec.h"

using namespace ybar::model;

TEST_CASE("full spec parses family, style, and size") {
    FontSpec font;
    REQUIRE(font.apply("Hack Nerd Font:Bold:14.0"));
    CHECK(font.family == "Hack Nerd Font");
    CHECK(font.style == "Bold");
    CHECK(font.size == 14.0);
}

TEST_CASE("empty components preserve current values") {
    FontSpec font{"SF Pro", "Regular", 13.0};
    REQUIRE(font.apply(":Semibold:"));
    CHECK(font.family == "SF Pro");
    CHECK(font.style == "Semibold");
    CHECK(font.size == 13.0);
    REQUIRE(font.apply("::16"));
    CHECK(font.size == 16.0);
}

TEST_CASE("invalid size component fails without clobbering") {
    FontSpec font{"A", "B", 12.0};
    CHECK_FALSE(font.apply("::abc"));
    CHECK(font.size == 12.0);
    CHECK_FALSE(font.apply("::0"));
}

TEST_CASE("serializes as Family:Style:size with one decimal") {
    CHECK(FontSpec{"Hack", "Bold", 14.0}.serialize() == "Hack:Bold:14.0");
    CHECK(FontSpec{"", "", 13.5}.serialize() == "::13.5");
}
