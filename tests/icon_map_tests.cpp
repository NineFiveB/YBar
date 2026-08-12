// sf: icon-resolver contract tests (spec 7.5 / decision D11): the GRAMMAR is
// the contract, the artwork is platform-specific.

#include <catch2/catch_test_macros.hpp>

#include "render/icon_map.h"

using namespace ybar::render;

namespace {

// UTF-8 of a PUA codepoint, for comparing against the table's output.
std::string utf8(char32_t codepoint) {
    std::string out;
    out.push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
    out.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
    out.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    return out;
}

} // namespace

TEST_CASE("both sf prefixes are recognized") {
    CHECK(symbolName("sf:wifi") == "wifi");
    CHECK(symbolName("sf.wifi") == "wifi"); // image-source spelling
    CHECK(symbolName("wifi").empty());      // plain text is not a symbol
    CHECK(symbolName("sf:").empty());       // prefix alone is not a name
    CHECK(symbolName("").empty());
}

TEST_CASE("known names resolve to icon-font glyphs") {
    const auto wifi = resolveSymbol("wifi");
    CHECK(wifi.mapped);
    CHECK(wifi.text == utf8(0xE701));
    CHECK(resolveSymbol("clock").text == utf8(0xE823));
    CHECK(resolveSymbol("calendar").text == utf8(0xE787));
}

TEST_CASE("dotted names fall back progressively") {
    // speaker.wave.2.fill -> speaker.wave.2 (listed)
    const auto speaker = resolveSymbol("speaker.wave.2.fill");
    CHECK(speaker.mapped);
    CHECK(speaker.text == utf8(0xE994));
    // battery.75percent is listed exactly.
    CHECK(resolveSymbol("battery.75percent").text == utf8(0xE854));
    // An unlisted variant falls back to the family entry.
    CHECK(resolveSymbol("battery.12percent.fill").text == utf8(0xE83F));
}

TEST_CASE("unknown names yield a placeholder, never empty text") {
    const auto unknown = resolveSymbol("definitely.not.a.symbol");
    CHECK_FALSE(unknown.mapped);
    CHECK_FALSE(unknown.text.empty()); // renders a visible placeholder
}

TEST_CASE("every symbol used by the shipped themes resolves") {
    // Collected from examples/ — these must not regress to placeholders.
    for (const char* name :
         {"appletv", "applewatch", "backward.fill", "battery.75percent", "calendar", "clock",
          "cpu", "forward.fill", "gearshape", "keyboard", "laptopcomputer", "macwindow",
          "music.note", "pause.fill", "play.fill", "repeat", "repeat.1", "shuffle",
          "speaker.wave.2.fill", "storefront", "wifi"}) {
        INFO("symbol: " << name);
        CHECK(resolveSymbol(name).mapped);
    }
}
