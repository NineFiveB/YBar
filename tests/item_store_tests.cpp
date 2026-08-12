// ItemStore contract tests (CoreTests.swift parity) — docs/WINDOWS-PORT.md
// sections 3.3, 8.

#include <catch2/catch_test_macros.hpp>

#include "model/item.h"
#include "model/property_setter.h"

using namespace ybar::model;

namespace {
std::vector<std::string> order(const ItemStore& store) {
    std::vector<std::string> names;
    for (const auto& item : store.items()) names.push_back(item->name);
    return names;
}
} // namespace

TEST_CASE("add rejects duplicate names") {
    ItemStore store;
    REQUIRE(store.add("a", ItemPosition::Left));
    CHECK(store.add("a", ItemPosition::Right) == nullptr);
}

TEST_CASE("defaults prototype applies the exact field list") {
    ItemStore store;
    CHECK_FALSE(PropertySetter::set(store.defaults(), "label.color", "0xffaabbcc"));
    CHECK_FALSE(PropertySetter::set(store.defaults(), "padding_left", "7"));
    CHECK_FALSE(PropertySetter::set(store.defaults(), "script", "echo hi"));
    CHECK_FALSE(PropertySetter::set(store.defaults(), "drawing", "off")); // NOT copied

    auto* item = store.add("a", ItemPosition::Left);
    REQUIRE(item);
    CHECK(item->label.color.argb == 0xffaabbccu);
    CHECK(item->paddingLeft == 7);
    CHECK(item->script == "echo hi");
    CHECK(item->drawing); // drawing is not part of the defaults copy list

    store.resetDefaults();
    auto* fresh = store.add("b", ItemPosition::Left);
    REQUIRE(fresh);
    CHECK(fresh->label.color.argb == 0xffffffffu);
}

TEST_CASE("move before/after an anchor") {
    ItemStore store;
    store.add("a", ItemPosition::Left);
    store.add("b", ItemPosition::Left);
    store.add("c", ItemPosition::Left);

    CHECK(store.move("c", /*before=*/true, "a"));
    CHECK(order(store) == std::vector<std::string>{"c", "a", "b"});
    CHECK(store.move("c", /*before=*/false, "b"));
    CHECK(order(store) == std::vector<std::string>{"a", "b", "c"});

    CHECK_FALSE(store.move("a", true, "a"));       // self anchor
    CHECK_FALSE(store.move("a", true, "missing")); // missing anchor is a no-op
    CHECK(order(store) == std::vector<std::string>{"a", "b", "c"});
}

TEST_CASE("reorder swaps listed items into each other's slots") {
    ItemStore store;
    store.add("a", ItemPosition::Left);
    store.add("b", ItemPosition::Left);
    store.add("c", ItemPosition::Left);
    store.add("d", ItemPosition::Left);

    CHECK(store.reorder({"c", "a"})); // slots {0,2} filled in given order
    CHECK(order(store) == std::vector<std::string>{"c", "b", "a", "d"});

    CHECK_FALSE(store.reorder({"a", "missing"}));
    CHECK_FALSE(store.reorder({"a", "a"}));
    CHECK(order(store) == std::vector<std::string>{"c", "b", "a", "d"});
}

TEST_CASE("rename fixes bracket members and popup hosts") {
    ItemStore store;
    store.add("volume", ItemPosition::Right);
    auto* bracket = store.add("widgets", ItemPosition::Right, ItemKind::Bracket);
    bracket->members = {"volume", "battery"};
    auto* member = store.add("volume.popup.row", ItemPosition::Left);
    member->position = ItemPosition::Popup;
    member->popupHost = "volume";

    CHECK(store.rename("volume", "audio"));
    CHECK(store.find("audio"));
    CHECK_FALSE(store.find("volume"));
    CHECK(bracket->members == std::vector<std::string>{"audio", "battery"});
    CHECK(member->popupHost == "audio");

    CHECK_FALSE(store.rename("missing", "x"));
    store.add("taken", ItemPosition::Left);
    CHECK_FALSE(store.rename("audio", "taken"));
}

TEST_CASE("clone copies value fields but never components or kind") {
    ItemStore store;
    auto* src = store.add("src", ItemPosition::Left, ItemKind::Bracket);
    CHECK_FALSE(PropertySetter::set(*src, "label", "text"));
    CHECK_FALSE(PropertySetter::set(*src, "width", "50"));
    src->graph.emplace();
    src->members = {"m1"};

    auto* copy = store.clone("copy", "src", ItemStore::Placement::After);
    REQUIRE(copy);
    CHECK(copy->label.string == "text");
    CHECK(copy->customWidth == 50);
    CHECK(copy->members == std::vector<std::string>{"m1"});
    CHECK_FALSE(copy->graph.has_value());     // components deliberately not copied
    CHECK(copy->kind == ItemKind::Item);      // reference clones through add()
    CHECK(order(store) == std::vector<std::string>{"src", "copy"});
}

TEST_CASE("clone placement: append by default, adjacent when asked") {
    ItemStore store;
    store.add("a", ItemPosition::Left);
    store.add("b", ItemPosition::Left);
    store.add("c", ItemPosition::Left);

    REQUIRE(store.clone("a-copy", "a", ItemStore::Placement::Append));
    CHECK(order(store) == std::vector<std::string>{"a", "b", "c", "a-copy"});

    REQUIRE(store.clone("b-before", "b", ItemStore::Placement::Before));
    CHECK(order(store) == std::vector<std::string>{"a", "b-before", "b", "c", "a-copy"});
}

TEST_CASE("regex targets match unanchored substrings") {
    ItemStore store;
    store.add("bt.device.airpods", ItemPosition::Left);
    store.add("bt.device.keyboard", ItemPosition::Left);
    store.add("volume", ItemPosition::Left);

    const auto matched = store.matching("/bt.device\\..*/");
    CHECK(matched.size() == 2);

    // Unanchored: a mid-name fragment matches too (regexec parity).
    CHECK(store.matching("/device/").size() == 2);
    CHECK(store.matching("volume").size() == 1);
    CHECK(store.matching("/[invalid/").empty()); // bad regex matches nothing
}

TEST_CASE("visibility rule") {
    ItemStore store;
    auto* item = store.add("a", ItemPosition::Left);
    CHECK(item->isVisibleInFlow()); // icon+label drawing default on
    item->icon.drawing = false;
    item->label.drawing = false;
    CHECK_FALSE(item->isVisibleInFlow());
    item->customWidth = 10;
    CHECK(item->isVisibleInFlow());
    item->customWidth = -1;
    item->graph.emplace();
    CHECK(item->isVisibleInFlow());
    item->graph.reset();
    item->drawing = false;
    item->label.drawing = true;
    CHECK_FALSE(item->isVisibleInFlow());
}

TEST_CASE("expandMembers preserves order and de-duplicates") {
    ItemStore store;
    store.add("a1", ItemPosition::Left);
    store.add("a2", ItemPosition::Left);
    store.add("b", ItemPosition::Left);

    const auto expanded = store.expandMembers({"/a./", "a1", "b"});
    REQUIRE(expanded.size() == 3);
    CHECK(expanded[0]->name == "a1");
    CHECK(expanded[1]->name == "a2");
    CHECK(expanded[2]->name == "b");
}
