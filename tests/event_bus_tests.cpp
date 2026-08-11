// EventBus contract tests (CoreTests.swift, ReviewFixTests.swift parity) —
// docs/WINDOWS-PORT.md section 3.4.

#include <catch2/catch_test_macros.hpp>

#include "events/event_bus.h"

using namespace ybar::events;
using namespace ybar::model;

TEST_CASE("builtin events occupy fixed bits in declaration order") {
    EventBus bus;
    CHECK(bus.eventBit("front_app_switched") == 1ull << 0);
    CHECK(bus.eventBit("space_change") == 1ull << 1);
    CHECK(bus.eventBit("media_change") == 1ull << 19);
    CHECK(bus.definitions().size() == 20);
    CHECK_FALSE(bus.eventBit("unknown"));
}

TEST_CASE("custom events append and cap at 64; duplicates are no-ops") {
    EventBus bus;
    CHECK_FALSE(bus.addEvent("komorebi_workspace_change"));
    CHECK(bus.eventBit("komorebi_workspace_change") == 1ull << 20);
    CHECK_FALSE(bus.addEvent("komorebi_workspace_change")); // silent no-op
    CHECK(bus.definitions().size() == 21);
    for (int i = 0; i < 43; ++i) CHECK_FALSE(bus.addEvent("e" + std::to_string(i)));
    CHECK(bus.addEvent("overflow") == "[!] event limit reached (64)");
}

TEST_CASE("reset drops custom events and keeps builtin bits stable") {
    EventBus bus;
    REQUIRE_FALSE(bus.addEvent("custom"));
    bus.reset();
    CHECK_FALSE(bus.eventBit("custom"));
    CHECK(bus.eventBit("media_change") == 1ull << 19);
}

TEST_CASE("trigger honors the updates policy and script/handler requirement") {
    EventBus bus;
    Item scripted;
    scripted.name = "scripted";
    scripted.script = "echo hi";
    Item silent;
    silent.name = "silent"; // no script, no Lua handlers
    Item off;
    off.name = "off";
    off.script = "echo hi";
    off.updatePolicy = UpdatePolicy::Off;
    Item whenShown;
    whenShown.name = "when_shown";
    whenShown.script = "echo hi";
    whenShown.updatePolicy = UpdatePolicy::WhenShown;
    whenShown.drawing = false; // gated on the drawing flag, not content

    for (auto* item : {&scripted, &silent, &off, &whenShown}) {
        REQUIRE(bus.subscribe(*item, "system_woke"));
    }

    std::vector<std::string> ran;
    bus.itemsProvider = [&] {
        return std::vector<Item*>{&scripted, &silent, &off, &whenShown};
    };
    bus.runItemScript = [&](Item& item, const Environment& env) {
        ran.push_back(item.name);
        CHECK(env.at("SENDER") == "system_woke");
    };

    bus.trigger("system_woke", "");
    CHECK(ran == std::vector<std::string>{"scripted"});

    whenShown.drawing = true;
    ran.clear();
    bus.trigger("system_woke", "");
    CHECK(ran == std::vector<std::string>{"scripted", "when_shown"});
}

TEST_CASE("NAME/SENDER/INFO cannot be spoofed by trigger extras") {
    EventBus bus;
    Item item;
    item.name = "real";
    item.script = "echo";
    REQUIRE(bus.subscribe(item, "system_woke"));
    bus.itemsProvider = [&] { return std::vector<Item*>{&item}; };

    Environment seen;
    bus.runItemScript = [&](Item&, const Environment& env) { seen = env; };
    bus.trigger("system_woke", "payload",
                {{"NAME", "spoof"}, {"SENDER", "spoof"}, {"CUSTOM", "yes"}});
    CHECK(seen.at("NAME") == "real");
    CHECK(seen.at("SENDER") == "system_woke");
    CHECK(seen.at("INFO") == "payload");
    CHECK(seen.at("CUSTOM") == "yes"); // arbitrary extras pass through
}

TEST_CASE("targeted mouse dispatch bypasses the updates policy") {
    EventBus bus;
    Item item;
    item.name = "a";
    item.script = "echo";
    item.updatePolicy = UpdatePolicy::Off;

    bool ran = false;
    bus.runItemScript = [&](Item&, const Environment& env) {
        ran = true;
        CHECK(env.at("SENDER") == "mouse.clicked");
        CHECK(env.at("BUTTON") == "left");
    };
    bus.triggerTargeted(item, "mouse.clicked", "", {{"BUTTON", "left"}, {"MODIFIER", "none"}});
    CHECK(ran);
}

TEST_CASE("first subscription arms the provider hook once") {
    EventBus bus;
    std::vector<std::string> armed;
    bus.onFirstSubscription = [&](const std::string& name) { armed.push_back(name); };
    Item a, b;
    REQUIRE(bus.subscribe(a, "volume_change"));
    REQUIRE(bus.subscribe(b, "volume_change"));
    REQUIRE(bus.subscribe(a, "wifi_change"));
    CHECK(armed == std::vector<std::string>{"volume_change", "wifi_change"});
}
