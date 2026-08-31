// Property-grammar contract tests ported from the reference suite
// (CoreTests.swift, ReviewFixTests.swift) — docs/WINDOWS-PORT.md section 3.3.

#include <catch2/catch_test_macros.hpp>

#include "model/item.h"
#include "model/property_setter.h"

using namespace ybar::model;

namespace {
Item makeItem() {
    Item item;
    item.name = "test";
    return item;
}
} // namespace

TEST_CASE("bare icon/label set the string") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "label", "hello"));
    CHECK_FALSE(PropertySetter::set(item, "icon", "sf:wifi"));
    CHECK(item.label.string == "hello");
    CHECK(item.icon.string == "sf:wifi");
}

TEST_CASE("nested color paths and channels") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "label.color", "0xffff0000"));
    CHECK(item.label.color.argb == 0xffff0000u);
    CHECK_FALSE(PropertySetter::set(item, "label.color.alpha", "0.5"));
    CHECK(((item.label.color.argb >> 24) & 0xff) == 0x80);
    CHECK_FALSE(PropertySetter::set(item, "icon.background.shadow.color", "0xff112233"));
    CHECK(item.icon.background.shadow.color.argb == 0xff112233u);
    CHECK(PropertySetter::set(item, "label.color.chroma", "1") ==
          "[?] unknown color channel: chroma");
}

TEST_CASE("setting background.color auto-enables drawing") {
    auto item = makeItem();
    REQUIRE_FALSE(item.background.drawing);
    CHECK_FALSE(PropertySetter::set(item, "background.color", "0xff313244"));
    CHECK(item.background.drawing);
}

TEST_CASE("bool grammar and toggle") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "drawing", "off"));
    CHECK_FALSE(item.drawing);
    CHECK_FALSE(PropertySetter::set(item, "drawing", "toggle"));
    CHECK(item.drawing);
    CHECK_FALSE(PropertySetter::set(item, "icon.highlight", "YES"));
    CHECK(item.icon.highlight);
    CHECK(PropertySetter::set(item, "drawing", "maybe") == "[!] invalid boolean: maybe");
}

TEST_CASE("width accepts numbers and the dynamic sentinel") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "width", "120"));
    CHECK(item.customWidth == 120);
    CHECK_FALSE(PropertySetter::set(item, "width", "dynamic"));
    CHECK(item.customWidth == -1);
    CHECK_FALSE(PropertySetter::set(item, "label.width", "0"));
    CHECK(item.label.customWidth == 0);
}

TEST_CASE("display list becomes a 1-based bitmask") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "display", "1,3"));
    CHECK(item.associatedDisplayMask == 0b101u);
    CHECK_FALSE(PropertySetter::set(item, "display", "active"));
    CHECK(item.associatedToActiveDisplay);
    CHECK(PropertySetter::set(item, "display", "0") == "[!] invalid display list: 0");
    CHECK(PropertySetter::set(item, "display", "1,x") == "[!] invalid display list: 1,x");
}

TEST_CASE("update_freq validates a non-negative integer and resets the counter") {
    auto item = makeItem();
    item.routineCounter = 3;
    CHECK_FALSE(PropertySetter::set(item, "update_freq", "30"));
    CHECK(item.updateFrequency == 30);
    CHECK(item.routineCounter == 0);
    // Errors name their property (reference strings).
    CHECK(PropertySetter::set(item, "update_freq", "2.5") == "[!] invalid update_freq: 2.5");
    CHECK(PropertySetter::set(item, "update_freq", "-1") == "[!] invalid update_freq: -1");
}

TEST_CASE("updates policy accepts on/off/when_shown") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "updates", "when_shown"));
    CHECK(item.updatePolicy == UpdatePolicy::WhenShown);
    CHECK_FALSE(PropertySetter::set(item, "updates", "off"));
    CHECK(item.updatePolicy == UpdatePolicy::Off);
    CHECK_FALSE(PropertySetter::set(item, "updates", "1"));
    CHECK(item.updatePolicy == UpdatePolicy::On);
}

TEST_CASE("sketchybar compat keys are accepted and ignored") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "padding_top", "4"));
    CHECK_FALSE(PropertySetter::set(item, "space", "2"));
    CHECK_FALSE(PropertySetter::set(item, "associated_space", "2"));
    CHECK_FALSE(PropertySetter::set(item, "mach_helper", "git.foo.bar"));
    CHECK_FALSE(PropertySetter::set(item, "shadow", "on"));
    CHECK_FALSE(PropertySetter::set(item, "icon.font.features", "ss01"));
    CHECK_FALSE(PropertySetter::set(item, "popup.topmost", "on"));
    CHECK_FALSE(PropertySetter::set(item, "alias.color", "0xff000000"));
    CHECK_FALSE(PropertySetter::set(item, "alias.update_freq", "5"));
    CHECK_FALSE(PropertySetter::set(item, "background.image.whatever", "x"));
}

TEST_CASE("unknown properties report the full path") {
    auto item = makeItem();
    CHECK(PropertySetter::set(item, "bogus", "1") == "[?] unknown property: bogus");
    CHECK(PropertySetter::set(item, "label.bogus", "1") == "[?] unknown property: label.bogus");
}

TEST_CASE("font partial application preserves unset components") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "label.font", "Hack Nerd Font:Bold:14.0"));
    CHECK(item.label.font.family == "Hack Nerd Font");
    CHECK(item.label.font.style == "Bold");
    CHECK(item.label.font.size == 14.0);
    CHECK_FALSE(PropertySetter::set(item, "label.font", ":Regular:"));
    CHECK(item.label.font.family == "Hack Nerd Font");
    CHECK(item.label.font.style == "Regular");
    CHECK(item.label.font.size == 14.0);
    CHECK_FALSE(PropertySetter::set(item, "label.font.size", "18"));
    CHECK(item.label.font.size == 18.0);
}

TEST_CASE("graph paths require an existing graph") {
    auto item = makeItem();
    CHECK(PropertySetter::set(item, "graph.color", "0xffffffff") == "[!] test is not a graph");
    item.graph.emplace();
    CHECK_FALSE(PropertySetter::set(item, "graph.color", "0xff00ff00"));
    CHECK(item.graph->lineColor.argb == 0xff00ff00u);
    CHECK(item.graph->effectiveFillColor().argb == 0x3300ff00u); // 20% alpha derivation
}

TEST_CASE("gauge and image are lazily created") {
    auto item = makeItem();
    REQUIRE_FALSE(item.gauge);
    CHECK_FALSE(PropertySetter::set(item, "gauge.percentage", "150"));
    REQUIRE(item.gauge);
    CHECK(item.gauge->percentage == 100); // clamped
    CHECK_FALSE(PropertySetter::set(item, "gauge.size", "4"));
    CHECK(item.gauge->size == 8); // min 8

    REQUIRE_FALSE(item.image);
    CHECK_FALSE(PropertySetter::set(item, "image", "app.Terminal"));
    REQUIRE(item.image);
    CHECK(item.image->source == "app.Terminal");
    CHECK_FALSE(PropertySetter::set(item, "image.align", "right"));
    CHECK(item.image->align == 'r');
}

TEST_CASE("slider percentage is ignored while dragging") {
    auto item = makeItem();
    item.slider.emplace();
    CHECK_FALSE(PropertySetter::set(item, "slider.percentage", "40"));
    CHECK(item.slider->percentage == 40);
    item.slider->isDragged = true;
    CHECK_FALSE(PropertySetter::set(item, "slider.percentage", "80"));
    CHECK(item.slider->percentage == 40);
}

TEST_CASE("slider.interactive marks a read-only meter") {
    // A slider used as a battery/level meter must not be scrubbable: the
    // daemon's press path skips the drag entirely when interactive=off, so a
    // click can never rewrite the displayed percentage.
    auto item = makeItem();
    item.slider.emplace();
    CHECK(item.slider->interactive); // interactive by default (volume sliders)
    CHECK_FALSE(PropertySetter::set(item, "slider.interactive", "off"));
    CHECK_FALSE(item.slider->interactive);
    // Sets still apply — only the pointer-driven path is disabled.
    CHECK_FALSE(PropertySetter::set(item, "slider.percentage", "55"));
    CHECK(item.slider->percentage == 55);
    CHECK_FALSE(PropertySetter::set(item, "slider.interactive", "on"));
    CHECK(item.slider->interactive);
}

TEST_CASE("popup properties") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "popup.drawing", "toggle"));
    CHECK(item.popup.isOpen);
    CHECK_FALSE(PropertySetter::set(item, "popup.wrap_width", "-5"));
    CHECK(item.popup.wrapWidth == 0); // clamped to >= 0
    CHECK_FALSE(PropertySetter::set(item, "popup.auto_close", "off"));
    CHECK_FALSE(item.popup.autoClose);
    CHECK_FALSE(PropertySetter::set(item, "popup.background.shadow.color", "0xff000000"));
    CHECK_FALSE(PropertySetter::set(item, "popup.background.corner_radius", "12"));
    CHECK(item.popup.background.cornerRadius == 12);
}

TEST_CASE("max_chars truncates the display string with an ellipsis") {
    auto item = makeItem();
    CHECK_FALSE(PropertySetter::set(item, "label", "hello world"));
    CHECK_FALSE(PropertySetter::set(item, "label.max_chars", "5"));
    CHECK(item.label.displayString() == "hello\xe2\x80\xa6");
    CHECK_FALSE(PropertySetter::set(item, "label.max_chars", "0"));
    CHECK(item.label.displayString() == "hello world");
}

TEST_CASE("position parsing accepts aliases and rejects popup") {
    CHECK(parsePosition("left") == ItemPosition::Left);
    CHECK(parsePosition("l") == ItemPosition::Left);
    CHECK(parsePosition("q") == ItemPosition::CenterLeft);
    CHECK(parsePosition("center_right") == ItemPosition::CenterRight);
    CHECK_FALSE(parsePosition("p"));
    CHECK_FALSE(parsePosition("popup"));
    CHECK_FALSE(parsePosition("top"));
}
