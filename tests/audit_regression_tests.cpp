// Regressions for the 2026-08 spec-compliance audit. Each case pins a
// divergence that a four-way review found between the implementation and
// docs/WINDOWS-PORT.md (plus the Swift reference it designates as the
// behavior authority).

#include <catch2/catch_test_macros.hpp>

#include "anim/scheduler.h"
#include "app/jsonc_config.h"
#include "events/event_bus.h"
#include "ipc/command_handler.h"
#include "model/item.h"
#include "model/popup_layout.h"
#include "model/property_setter.h"
#include "model/serialize.h"

using namespace ybar::model;

namespace {

struct Fixture {
    ItemStore store;
    BarSettings settings;
    ybar::events::EventBus bus;
    ybar::anim::AnimationScheduler scheduler;
    ybar::ipc::CommandHandler handler{store, settings, bus, {}, &scheduler};

    std::string run(std::vector<std::string> argv) { return handler.handle(argv); }
};

} // namespace

// --- UB class -------------------------------------------------------------

TEST_CASE("animating clip/wrap_width/gradient_color/fill_color never dangles") {
    // These four paths used to route a STACK LOCAL through the animatable
    // setter; the scheduler kept the capture alive and wrote through a dead
    // reference on every tick.
    ItemStore store;
    ybar::anim::AnimationScheduler scheduler;
    auto* item = store.add("a", ItemPosition::Left);
    item->graph.emplace();

    PropertySetter::AnimationContext context;
    context.scheduler = &scheduler;
    context.curve = ybar::anim::Curve::Linear;
    context.frames = 30;
    context.itemId = item->id;

    PropertySetter::beginAnimation(context);
    CHECK_FALSE(PropertySetter::set(*item, "background.clip", "8"));
    CHECK_FALSE(PropertySetter::set(*item, "popup.wrap_width", "120"));
    CHECK_FALSE(PropertySetter::set(*item, "background.gradient_color", "0xff00ff00"));
    CHECK_FALSE(PropertySetter::set(*item, "graph.fill_color", "0xff0000ff"));
    PropertySetter::endAnimation();

    // Non-animatable leaves land immediately; the animated color is in flight.
    CHECK(item->background.clip == 8);
    CHECK(item->popup.wrapWidth == 120);

    for (double t = 0; t <= 1.0; t += 0.1) scheduler.tick(t); // no UB, no crash
    REQUIRE(item->graph->fillColor.has_value());
    CHECK(item->graph->fillColor->argb == 0xff0000ffu);
    REQUIRE(item->background.gradientColor.has_value());
    CHECK(item->background.gradientColor->argb == 0xff00ff00u);
}

TEST_CASE("JSONC with non-string values reports an error instead of crashing") {
    CHECK(ybar::app::translateJsonc(R"({"items":[{"name": 5}]})", "t.jsonc").empty());
    CHECK(ybar::app::translateJsonc(R"({"items":[{"name":"a","bracket":[1,2]}]})", "t.jsonc").empty());
    CHECK(ybar::app::translateJsonc(R"({"items":[{"name":"a","subscribe":[7]}]})", "t.jsonc").empty());
    CHECK(ybar::app::translateJsonc(R"({"items":[{"name":"a","position":3}]})", "t.jsonc").empty());
}

// --- contract breaks ------------------------------------------------------

TEST_CASE("targeted mouse dispatch still honors the subscription mask") {
    ybar::events::EventBus bus;
    Item subscribed;
    subscribed.name = "sub";
    subscribed.script = "echo";
    REQUIRE(bus.subscribe(subscribed, "mouse.clicked"));
    Item unsubscribed;
    unsubscribed.name = "unsub";
    unsubscribed.script = "echo"; // scripted but never subscribed

    std::vector<std::string> ran;
    bus.runItemScript = [&](Item& item, const ybar::events::Environment&) {
        ran.push_back(item.name);
    };
    bus.triggerTargeted(subscribed, "mouse.clicked", "");
    bus.triggerTargeted(unsubscribed, "mouse.clicked", "");
    CHECK(ran == std::vector<std::string>{"sub"});
}

TEST_CASE("a bad token does not discard the rest of the batch") {
    Fixture f;
    f.run({"--add", "item", "a", "left"});
    const auto reply = f.run({"--set", "a", "bogus", "label=hi"});
    CHECK(reply == "[!] expected key=value, got: bogus");
    CHECK(f.store.find("a")->label.string == "hi"); // set still applied
}

TEST_CASE("query bar emits real booleans for hidden/sticky/idle_inhibit") {
    Fixture f;
    const auto json = f.run({"--query", "bar"});
    CHECK(json.find("\"hidden\": false") != std::string::npos);
    CHECK(json.find("\"sticky\": true") != std::string::npos);
    CHECK(json.find("\"idle_inhibit\": false") != std::string::npos);
}

TEST_CASE("graph/slider adds report duplicate names like --add item") {
    Fixture f;
    f.run({"--add", "item", "dup", "left"});
    CHECK(f.run({"--add", "graph", "dup", "left", "60"}) ==
          "[!] invalid position or duplicate name: dup left");
    CHECK(f.run({"--add", "slider", "dup", "left", "100"}) ==
          "[!] invalid position or duplicate name: dup left");
    // Popup hosts are validated for components too.
    CHECK(f.run({"--add", "graph", "g", "popup.missing", "60"}) ==
          "[!] invalid position or duplicate name: g popup.missing");
}

TEST_CASE("verbs tolerate trailing arguments like the reference") {
    Fixture f;
    CHECK(f.run({"--add", "item", "a", "left", "extra"}).empty());
    CHECK(f.run({"--query", "bar", "extra"}).find("\"height\"") != std::string::npos);
    CHECK(f.run({"--remove", "a", "extra"}).empty());
}

TEST_CASE("bracket members may be regexes that match nothing yet") {
    Fixture f;
    CHECK(f.run({"--add", "bracket", "b", "/space\\..*/"}).empty());
    CHECK(f.run({"--add", "bracket", "b2", "nosuch"}) == "[!] unknown bracket members: nosuch");
}

TEST_CASE("trigger tokens without '=' are skipped, not injected as empty vars") {
    Fixture f;
    f.run({"--add", "item", "x", "left"});
    f.store.find("x")->script = "echo";
    f.run({"--subscribe", "x", "system_woke"});
    ybar::events::Environment seen;
    f.bus.itemsProvider = [&] { return std::vector<Item*>{f.store.find("x")}; };
    f.bus.runItemScript = [&](Item&, const ybar::events::Environment& env) { seen = env; };
    f.run({"--trigger", "system_woke", "BARE", "KEY=value"});
    CHECK(seen.count("BARE") == 0);
    CHECK(seen.at("KEY") == "value");
}

// --- parity minors --------------------------------------------------------

TEST_CASE("align accepts only l/c/r") {
    Item item;
    CHECK_FALSE(PropertySetter::set(item, "align", "c"));
    CHECK(PropertySetter::set(item, "align", "x") == "[!] invalid align: x");
    CHECK(PropertySetter::set(item, "label.align", "top") == "[!] invalid align: top");
    CHECK(item.align == 'c'); // unchanged by the rejected set
}

TEST_CASE("non-finite numbers are rejected") {
    Item item;
    CHECK(PropertySetter::set(item, "padding_left", "inf") == "[!] invalid number: inf");
    CHECK(PropertySetter::set(item, "y_offset", "nan") == "[!] invalid number: nan");
}

TEST_CASE("error strings name their property") {
    Item item;
    CHECK(PropertySetter::set(item, "update_freq", "x") == "[!] invalid update_freq: x");
    CHECK(PropertySetter::set(item, "updates", "x") == "[!] invalid updates: x");
    CHECK(PropertySetter::set(item, "label.max_chars", "x") == "[!] invalid max_chars: x");
    CHECK(PropertySetter::set(item, "label.scroll_duration", "x") ==
          "[!] invalid scroll_duration: x");
    CHECK(PropertySetter::set(item, "background", "1") == "[!] background needs a sub-property");
}

TEST_CASE("display lists drop empty components") {
    Item item;
    CHECK_FALSE(PropertySetter::set(item, "display", "1,2,"));
    CHECK(item.associatedDisplayMask == 0b11u);
    CHECK_FALSE(PropertySetter::set(item, "display", "")); // mask 0 = all displays
    CHECK(item.associatedDisplayMask == 0u);
}

TEST_CASE("a fresh graph is pre-filled to capacity") {
    GraphState graph;
    graph.setCapacity(8);
    CHECK(graph.ordered().size() == 8);
    graph.push(1.0);
    CHECK(graph.ordered().size() == 8); // ring stays full-width
    CHECK(graph.ordered().back() == 1.0);
}

TEST_CASE("hidden popup members collapse instead of holding a separator row") {
    Item shown;
    shown.name = "shown";
    shown.label.string = "row";
    Item hidden;
    hidden.name = "hidden";
    hidden.label.string = "row";
    hidden.drawing = false;

    const auto measure = [](const Item&) {
        return MeasuredContent{{10, 12}, {10, 12}};
    };
    PopupState popup;
    const auto both = layoutPopup({&shown, &hidden}, popup, measure);
    const auto onlyShown = layoutPopup({&shown}, popup, measure);
    CHECK(both.panelSize.height == onlyShown.panelSize.height);
}
