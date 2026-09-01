// CommandHandler verb-surface tests (spec section 3.2). Exercises the same
// entry point socket clients hit.

#include <catch2/catch_test_macros.hpp>

#include "ipc/command_handler.h"

using namespace ybar::ipc;
using namespace ybar::model;

namespace {

struct Fixture {
    ItemStore store;
    BarSettings settings;
    ybar::events::EventBus bus;
    CommandHandler handler{store, settings, bus, {}};

    std::string run(std::vector<std::string> argv) { return handler.handle(argv); }
};

} // namespace

TEST_CASE("ping replies pong") {
    Fixture f;
    CHECK(f.run({"--ping"}) == "pong");
}

TEST_CASE("unknown domains error") {
    Fixture f;
    CHECK(f.run({"--bogus"}) == "[!] unknown domain: --bogus");
}

TEST_CASE("add/set/query round trip") {
    Fixture f;
    CHECK(f.run({"--add", "item", "clock", "right"}).empty());
    CHECK(f.run({"--set", "clock", "label=12:00", "label.color=0xffff0000"}).empty());
    REQUIRE(f.store.find("clock"));
    CHECK(f.store.find("clock")->label.string == "12:00");

    const auto json = f.run({"--query", "clock"});
    CHECK(json.find("\"name\": \"clock\"") != std::string::npos);
    CHECK(json.find("\"0xffff0000\"") != std::string::npos);
    CHECK(json.find("\"position\": \"right\"") != std::string::npos);
}

TEST_CASE("add validates usage and duplicates") {
    Fixture f;
    CHECK(f.run({"--add"}) == "[!] --add needs a type");
    CHECK(f.run({"--add", "item", "x"}) == "[!] usage: --add item <name> <position>");
    CHECK(f.run({"--add", "item", "x", "nowhere"}) ==
          "[!] invalid position or duplicate name: x nowhere");
    CHECK(f.run({"--add", "item", "x", "left"}).empty());
    CHECK(f.run({"--add", "item", "x", "left"}) ==
          "[!] invalid position or duplicate name: x left");
    CHECK(f.run({"--add", "widget", "x2", "left"}) ==
          "[!] unknown --add type: widget (supported: item, graph, slider, bracket, event)");
    CHECK(f.run({"--add", "alias", "Foo,Bar", "left"}) ==
          "[!] alias items are not supported on Windows");
}

TEST_CASE("popup members require an existing host") {
    Fixture f;
    CHECK(f.run({"--add", "item", "row", "popup.missing"}) ==
          "[!] invalid position or duplicate name: row popup.missing");
    CHECK(f.run({"--add", "item", "host", "left"}).empty());
    CHECK(f.run({"--add", "item", "row", "popup.host"}).empty());
    CHECK(f.store.find("row")->popupHost == "host");
    CHECK(f.store.find("row")->position == ItemPosition::Popup);
}

TEST_CASE("graph add validates capacity and push feeds it") {
    Fixture f;
    CHECK(f.run({"--add", "graph", "g", "left", "0"}) ==
          "[!] usage: --add graph <name> <position> <width> (1...8192)");
    CHECK(f.run({"--add", "graph", "g", "left", "60"}).empty());
    CHECK(f.run({"--push", "g", "0.5", "-0.25", "2"}).empty());
    REQUIRE(f.store.find("g")->graph);
    // The ring is pre-filled to capacity (reference), so pushes land at the
    // END of a full-width series.
    const auto samples = f.store.find("g")->graph->ordered();
    REQUIRE(samples.size() == 60);
    CHECK(samples[57] == 0.5);
    CHECK(samples[58] == 0.0); // clamped
    CHECK(samples[59] == 1.0); // clamped
    CHECK(f.run({"--push", "g", "abc"}) == "[!] invalid graph value: abc");
}

TEST_CASE("brackets validate members and enable background drawing") {
    Fixture f;
    CHECK(f.run({"--add", "bracket", "b", "missing"}) == "[!] unknown bracket members: missing");
    CHECK(f.run({"--add", "item", "m1", "left"}).empty());
    CHECK(f.run({"--add", "bracket", "b", "m1"}).empty());
    REQUIRE(f.store.find("b"));
    CHECK(f.store.find("b")->kind == ItemKind::Bracket);
    CHECK(f.store.find("b")->background.drawing);
}

TEST_CASE("subscribe validates item and event names") {
    Fixture f;
    CHECK(f.run({"--subscribe", "x", "system_woke"}) == "[!] no item named x");
    CHECK(f.run({"--add", "item", "x", "left"}).empty());
    CHECK(f.run({"--subscribe", "x", "nope"}) == "[!] unknown event: nope");
    CHECK(f.run({"--subscribe", "x", "system_woke", "media_change"}).empty());
    CHECK(f.store.find("x")->updateMask == ((1ull << 3) | (1ull << 19)));
}

TEST_CASE("bar and default domains route their setters") {
    Fixture f;
    CHECK(f.run({"--bar", "height=32", "color=0xdd1e1e2e"}).empty());
    CHECK(f.settings.height == 32);
    CHECK(f.settings.color.argb == 0xdd1e1e2eu);
    CHECK(f.run({"--bar", "height"}) == "[!] expected key=value, got: height");
    CHECK(f.run({"--bar", "topmost=maybe"}) == "[!] invalid topmost: maybe");

    CHECK(f.run({"--default", "label.color=0xff00ff00"}).empty());
    CHECK(f.run({"--add", "item", "y", "left"}).empty());
    CHECK(f.store.find("y")->label.color.argb == 0xff00ff00u);
    CHECK(f.run({"--default", "reset"}).empty());
    CHECK(f.run({"--add", "item", "z", "left"}).empty());
    CHECK(f.store.find("z")->label.color.argb == 0xffffffffu);
}

TEST_CASE("one message batches many domains and outputs join with newlines") {
    Fixture f;
    const auto out = f.run({"--add", "item", "a", "left", "--ping", "--set", "a", "label=hi"});
    CHECK(out == "pong");
    CHECK(f.store.find("a")->label.string == "hi");
}

TEST_CASE("trigger requires an event name and passes extras") {
    Fixture f;
    CHECK(f.run({"--trigger"}) == "[!] --trigger needs an event name");

    CHECK(f.run({"--add", "event", "custom_event"}).empty());
    CHECK(f.run({"--add", "item", "listener", "left"}).empty());
    f.store.find("listener")->script = "echo";
    CHECK(f.run({"--subscribe", "listener", "custom_event"}).empty());

    ybar::events::Environment seen;
    f.bus.itemsProvider = [&] { return std::vector<Item*>{f.store.find("listener")}; };
    f.bus.runItemScript = [&](Item&, const ybar::events::Environment& env) { seen = env; };
    CHECK(f.run({"--trigger", "custom_event", "INFO=hello", "FOCUSED_WORKSPACE=2"}).empty());
    CHECK(seen.at("INFO") == "hello");
    CHECK(seen.at("FOCUSED_WORKSPACE") == "2");
    CHECK(seen.at("SENDER") == "custom_event");
}

TEST_CASE("move/reorder/rename/clone/remove verb surface") {
    Fixture f;
    f.run({"--add", "item", "a", "left"});
    f.run({"--add", "item", "b", "left"});
    CHECK(f.run({"--move", "b", "before", "a"}).empty());
    CHECK(f.run({"--move", "b", "sideways", "a"}) ==
          "[!] usage: --move <name> before|after <anchor>");
    CHECK(f.run({"--rename", "b", "c"}).empty());
    CHECK(f.run({"--rename", "missing", "x"}) == "[!] could not rename missing");
    CHECK(f.run({"--clone", "c2", "c"}).empty());
    CHECK(f.run({"--reorder", "a", "zzz"}) == "[!] could not reorder (unknown names?)");
    CHECK(f.run({"--remove", "c2"}).empty());
    CHECK(f.run({"--remove", "c2"}) == "[!] no item matching c2");
}

TEST_CASE("query validates targets") {
    Fixture f;
    CHECK(f.run({"--query"}) == "[!] --query needs a target");
    CHECK(f.run({"--query", "nope"}) == "[!] no item named nope");
    const auto bar = f.run({"--query", "bar"});
    CHECK(bar.find("\"height\"") != std::string::npos);
    CHECK(bar.find("\"topmost\": \"off\"") != std::string::npos);
    const auto events = f.run({"--query", "events"});
    CHECK(events.find("\"front_app_switched\"") != std::string::npos);
    CHECK(events.find("\"(null)\"") != std::string::npos);
}

TEST_CASE("hotload validates its boolean and reaches the hook") {
    Fixture f;
    CHECK(f.run({"--hotload", "maybe"}) == "[!] usage: --hotload <on|off>");

    bool hotload = false;
    ItemStore store;
    BarSettings settings;
    ybar::events::EventBus bus;
    DaemonHooks hooks;
    hooks.setHotload = [&](bool on) { hotload = on; };
    CommandHandler handler{store, settings, bus, hooks};
    CHECK(handler.handle({"--hotload", "on"}).empty());
    CHECK(hotload);
}

TEST_CASE("window verb validates its arguments and reaches the hook") {
    // The tray widget's action verb (spec 10.6). Argument validation must
    // happen before the hook so a malformed hwnd can never reach Win32.
    Fixture f;
    CHECK(f.run({"--window"}) == "[!] usage: --window <hwnd> close|kill");
    CHECK(f.run({"--window", "123"}) == "[!] usage: --window <hwnd> close|kill");
    CHECK(f.run({"--window", "notanumber", "close"}) == "[!] invalid hwnd: notanumber");
    CHECK(f.run({"--window", "0", "close"}) == "[!] invalid hwnd: 0");
    // Trailing garbage must not parse as a valid handle.
    CHECK(f.run({"--window", "12x", "close"}) == "[!] invalid hwnd: 12x");
    // No hook wired (headless): reports unavailable rather than crashing.
    CHECK(f.run({"--window", "4242", "close"}) == "[!] window actions are not available");

    long long seen = 0;
    std::string seenAction;
    ItemStore store;
    BarSettings settings;
    ybar::events::EventBus bus;
    DaemonHooks hooks;
    hooks.windowAction = [&](long long hwnd, const std::string& action) {
        seen = hwnd;
        seenAction = action;
        return std::string{};
    };
    CommandHandler handler{store, settings, bus, hooks};
    CHECK(handler.handle({"--window", "4242", "kill"}).empty());
    CHECK(seen == 4242);
    CHECK(seenAction == "kill");
}

TEST_CASE("query windows returns the running-app list from the hook") {
    Fixture f;
    // Unwired (headless) yields an empty JSON array, never an item lookup.
    CHECK(f.run({"--query", "windows"}) == "[]");

    ItemStore store;
    BarSettings settings;
    ybar::events::EventBus bus;
    DaemonHooks hooks;
    hooks.runningApps = [] { return std::string("[{\"name\":\"Warp\"}]"); };
    CommandHandler handler{store, settings, bus, hooks};
    CHECK(handler.handle({"--query", "windows"}) == "[{\"name\":\"Warp\"}]");
}

TEST_CASE("tray verb validates its arguments and reaches the hook") {
    Fixture f;
    CHECK(f.run({"--tray"}) == "[!] usage: --tray <name> invoke");
    CHECK(f.run({"--tray", "OneDrive"}) == "[!] usage: --tray <name> invoke");
    CHECK(f.run({"--tray", "OneDrive", "poke"}) == "[!] usage: --tray <name> invoke");
    CHECK(f.run({"--tray", "OneDrive", "invoke"}) == "[!] tray actions are not available");
    // Unwired query yields an empty list, never an item lookup.
    CHECK(f.run({"--query", "tray"}) == "[]");

    std::string seen;
    ItemStore store;
    BarSettings settings;
    ybar::events::EventBus bus;
    DaemonHooks hooks;
    hooks.trayInvoke = [&](const std::string& name) {
        seen = name;
        return std::string{};
    };
    hooks.trayIcons = [] { return std::string("[{\"name\":\"NVIDIA Settings\"}]"); };
    CommandHandler handler{store, settings, bus, hooks};
    CHECK(handler.handle({"--tray", "NVIDIA Settings", "invoke"}).empty());
    CHECK(seen == "NVIDIA Settings");
    CHECK(handler.handle({"--query", "tray"}) == "[{\"name\":\"NVIDIA Settings\"}]");
}
