// Popup layout contract tests (ComponentTests.swift parity) — spec 3.9.

#include <catch2/catch_test_macros.hpp>

#include "model/popup_layout.h"

using namespace ybar::model;

namespace {

MeasuredContent fixedMeasure(const Item&) { return {{10, 12}, {30, 12}}; }

std::unique_ptr<Item> makeMember(const std::string& name) {
    auto item = std::make_unique<Item>();
    item->name = name;
    item->position = ItemPosition::Popup;
    item->icon.drawing = false; // label-only: length 30
    return item;
}

} // namespace

TEST_CASE("vertical stack: rows stacked, panel is the widest row plus insets") {
    auto a = makeMember("a");
    auto b = makeMember("b");
    b->paddingLeft = 4;
    const std::vector<Item*> members{a.get(), b.get()};
    PopupState popup;

    const auto layout = layoutPopup(members, popup, fixedMeasure);
    REQUIRE(layout.contentBoxes.size() == 2);
    // Row height = max(contentHeight 12 + 8, 22) = 22.
    CHECK(layout.contentBoxes[0] == Rect{6, 6, 30, 22});
    CHECK(layout.contentBoxes[1] == Rect{10, 28, 30, 22});
    CHECK(layout.panelSize == Size{34 + 12, 44 + 12}); // widest row 4+30, rows 44
}

TEST_CASE("fixed cellHeight overrides row height") {
    auto a = makeMember("a");
    const std::vector<Item*> members{a.get()};
    PopupState popup;
    popup.cellHeight = 40;
    const auto layout = layoutPopup(members, popup, fixedMeasure);
    CHECK(layout.contentBoxes[0].height == 40);
    CHECK(layout.panelSize.height == 52);
}

TEST_CASE("horizontal row normalizes cells to the tallest") {
    auto a = makeMember("a");
    auto b = makeMember("b");
    const std::vector<Item*> members{a.get(), b.get()};
    PopupState popup;
    popup.horizontal = true;
    const auto layout = layoutPopup(members, popup, fixedMeasure);
    CHECK(layout.contentBoxes[0] == Rect{6, 6, 30, 22});
    CHECK(layout.contentBoxes[1] == Rect{36, 6, 30, 22});
    CHECK(layout.panelSize == Size{72, 34});
}

TEST_CASE("wrap flow wraps lines and never wraps a line's first member") {
    auto a = makeMember("a");
    auto b = makeMember("b");
    auto c = makeMember("c");
    const std::vector<Item*> members{a.get(), b.get(), c.get()};
    PopupState popup;
    popup.wrapWidth = 50; // fits one 30-wide member per line (second would exceed)

    const auto layout = layoutPopup(members, popup, fixedMeasure);
    REQUIRE(layout.contentBoxes.size() == 3);
    CHECK(layout.contentBoxes[0].y == 6);
    CHECK(layout.contentBoxes[1].y == 28); // wrapped to line 2
    CHECK(layout.contentBoxes[2].y == 50);
    CHECK(layout.panelSize == Size{50 + 12, 72 + 6});

    // A single over-wide member still lays out (first of line never wraps).
    popup.wrapWidth = 10;
    const auto tight = layoutPopup({a.get()}, popup, fixedMeasure);
    CHECK(tight.contentBoxes[0] == Rect{6, 6, 30, 22});
}

TEST_CASE("empty member list yields an empty result") {
    PopupState popup;
    const auto layout = layoutPopup({}, popup, fixedMeasure);
    CHECK(layout.contentBoxes.empty());
    CHECK(layout.panelSize == Size{});
}
