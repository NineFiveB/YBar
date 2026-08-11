// Layout invariants ported from the reference suite (CoreTests.swift,
// ComponentTests.swift) — docs/WINDOWS-PORT.md section 3.9.

#include <catch2/catch_test_macros.hpp>

#include "model/layout.h"

using namespace ybar::model;

namespace {

// Fixed-size measurement: every drawn part measures 10 x 12.
MeasuredContent fixedMeasure(const Item&) { return {{10, 12}, {10, 12}}; }

std::unique_ptr<Item> makeItem(const std::string& name, ItemPosition position) {
    auto item = std::make_unique<Item>();
    item->name = name;
    item->position = position;
    return item;
}

} // namespace

TEST_CASE("left items flow right from the bar padding") {
    std::vector<std::unique_ptr<Item>> items;
    items.push_back(makeItem("a", ItemPosition::Left));
    items.push_back(makeItem("b", ItemPosition::Left));
    items[0]->paddingLeft = 5;
    LayoutSettings settings{400, 25, 10, 10, 0};
    const auto boxes = layout(items, settings, fixedMeasure);
    // a: starts at barPadding(10) + item padding(5); length = icon 10 + label 10.
    CHECK(boxes.at(items[0]->id) == Rect{15, 0, 20, 25});
    CHECK(boxes.at(items[1]->id) == Rect{35, 0, 20, 25});
    CHECK(items[0]->frame == Rect{10, 0, 25, 25}); // padded interactive extent
}

TEST_CASE("right items flow left from the bar edge") {
    std::vector<std::unique_ptr<Item>> items;
    items.push_back(makeItem("a", ItemPosition::Right));
    items.push_back(makeItem("b", ItemPosition::Right));
    LayoutSettings settings{400, 25, 0, 10, 0};
    const auto boxes = layout(items, settings, fixedMeasure);
    CHECK(boxes.at(items[0]->id) == Rect{370, 0, 20, 25}); // first declared = rightmost
    CHECK(boxes.at(items[1]->id) == Rect{350, 0, 20, 25});
}

TEST_CASE("the center block is centered as a unit") {
    std::vector<std::unique_ptr<Item>> items;
    items.push_back(makeItem("a", ItemPosition::Center));
    items.push_back(makeItem("b", ItemPosition::Center));
    LayoutSettings settings{400, 25, 0, 0, 0};
    const auto boxes = layout(items, settings, fixedMeasure);
    // Total = 40; block starts at 180.
    CHECK(boxes.at(items[0]->id) == Rect{180, 0, 20, 25});
    CHECK(boxes.at(items[1]->id) == Rect{200, 0, 20, 25});
}

TEST_CASE("q flows left and e flows right around the notch dead zone") {
    std::vector<std::unique_ptr<Item>> items;
    items.push_back(makeItem("q1", ItemPosition::CenterLeft));
    items.push_back(makeItem("e1", ItemPosition::CenterRight));
    LayoutSettings settings{400, 25, 0, 0, 100};
    const auto boxes = layout(items, settings, fixedMeasure);
    CHECK(boxes.at(items[0]->id) == Rect{130, 0, 20, 25}); // 200-50-20
    CHECK(boxes.at(items[1]->id) == Rect{250, 0, 20, 25}); // 200+50

    // With no notch (Windows default) both anchor at width/2.
    LayoutSettings flat{400, 25, 0, 0, 0};
    const auto flatBoxes = layout(items, flat, fixedMeasure);
    CHECK(flatBoxes.at(items[0]->id) == Rect{180, 0, 20, 25});
    CHECK(flatBoxes.at(items[1]->id) == Rect{200, 0, 20, 25});
}

TEST_CASE("fixed item width replaces the content length") {
    std::vector<std::unique_ptr<Item>> items;
    items.push_back(makeItem("a", ItemPosition::Left));
    items[0]->customWidth = 100;
    LayoutSettings settings{400, 25, 0, 0, 0};
    const auto boxes = layout(items, settings, fixedMeasure);
    CHECK(boxes.at(items[0]->id).width == 100);

    // naturalLength ignores the fixed width; contentLength honors it.
    const auto m = fixedMeasure(*items[0]);
    CHECK(naturalLength(*items[0], m) == 20);
    CHECK(contentLength(*items[0], m) == 100);
}

TEST_CASE("fixed text-part width replaces ink plus paddings; zero collapses") {
    TextPart part;
    part.paddingLeft = 4;
    part.paddingRight = 4;
    CHECK(partAdvance(part, {10, 12}) == 18);
    part.customWidth = 30;
    CHECK(partAdvance(part, {10, 12}) == 30); // paddings fold inside
    part.customWidth = 0;
    CHECK(partAdvance(part, {10, 12}) == 0); // collapses to exactly 0
    part.customWidth = -1;
    part.drawing = false;
    CHECK(partAdvance(part, {10, 12}) == 0);
}

TEST_CASE("invisible items and brackets take zero space") {
    std::vector<std::unique_ptr<Item>> items;
    items.push_back(makeItem("a", ItemPosition::Left));
    items.push_back(makeItem("hidden", ItemPosition::Left));
    items.push_back(makeItem("bracket", ItemPosition::Left));
    items[1]->drawing = false;
    items[2]->kind = ItemKind::Bracket;
    LayoutSettings settings{400, 25, 0, 0, 0};
    const auto boxes = layout(items, settings, fixedMeasure);
    CHECK(boxes.at(items[1]->id).isZero());
    CHECK(items[1]->frame.isZero());
    CHECK(boxes.at(items[2]->id).isZero());
    CHECK(boxes.at(items[0]->id) == Rect{0, 0, 20, 25}); // unaffected
}

TEST_CASE("graph natural length is capacity plus label (the sandwich)") {
    auto item = makeItem("g", ItemPosition::Left);
    item->graph.emplace();
    item->graph->capacity = 60;
    item->icon.drawing = false;
    const auto m = fixedMeasure(*item);
    CHECK(naturalLength(*item, m) == 70); // 60 capacity + 10 label
}

TEST_CASE("a gauge's label contributes zero flow width") {
    auto item = makeItem("g", ItemPosition::Left);
    item->gauge.emplace();
    item->gauge->size = 84;
    item->icon.drawing = false;
    const auto m = fixedMeasure(*item);
    CHECK(naturalLength(*item, m) == 84);
}

TEST_CASE("bracket frame is the padded union of member boxes at bar height") {
    std::vector<std::unique_ptr<Item>> items;
    items.push_back(makeItem("a", ItemPosition::Left));
    items.push_back(makeItem("b", ItemPosition::Left));
    LayoutSettings settings{400, 25, 0, 0, 0};
    const auto boxes = layout(items, settings, fixedMeasure);

    Item bracket;
    bracket.paddingLeft = 3;
    bracket.paddingRight = 5;
    const auto frame =
        bracketFrame(bracket, {items[0].get(), items[1].get()}, boxes, 25);
    CHECK(frame == Rect{-3, 0, 48, 25}); // union [0,40) padded

    const auto empty = bracketFrame(bracket, {}, boxes, 25);
    CHECK(empty.isZero());
}
