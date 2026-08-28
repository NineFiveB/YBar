// komorebi protocol contract tests (spec 11.2, 14). The recorded fixtures
// in tests/fixtures/komorebi were captured from a live komorebi v0.1.41
// over the real subscription socket; the synthetic-* fixtures are
// hand-written to spec 11.2 for shapes a single-monitor recording session
// cannot produce. The komorebi-canary CI job watches the latest release's
// schemas for drift away from what is pinned here.

#include <catch2/catch_test_macros.hpp>

#include <fstream>
#include <sstream>
#include <string>

#include <nlohmann/json.hpp>

#include "providers/komorebi.h"

using nlohmann::json;
using ybar::providers::KomorebiProvider;

namespace {

std::string readFixture(const char* name) {
    std::ifstream stream(std::string(YBAR_TEST_FIXTURE_DIR) + "/komorebi/" + name,
                         std::ios::binary);
    REQUIRE(stream.is_open());
    std::ostringstream buffer;
    buffer << stream.rdbuf();
    return buffer.str();
}

} // namespace

TEST_CASE("recorded State parses to the workspaces contract") {
    const auto update = KomorebiProvider::parseNotification(readFixture("state.json"));
    REQUIRE(update.has_value());
    CHECK(update->workspaceNames == "I\nII\nIII\nIV\nV\nVI\nVII");
    CHECK(update->focusedWorkspace == "I");
    CHECK(update->focusedIndex == 1);
    CHECK(update->focusedMonitorIndex == 0);
    CHECK(update->workspacesChanged);
}

TEST_CASE("recorded State carries the documented wire shapes") {
    // Fields the provider does not extract (yet) but the spec-11.2 contract
    // guarantees: Ring {elements, focused} at every level, the Window
    // quintet, Rect right/bottom as width/height.
    const auto state = json::parse(readFixture("state.json"));
    const auto& monitors = state.at("monitors");
    CHECK(monitors.at("focused") == 0);
    REQUIRE(monitors.at("elements").size() == 1);
    const auto& monitor = monitors.at("elements").at(0);
    CHECK(monitor.at("device_id") == "SDC419C-5&292e6c21&0&UID4353");
    const auto& workspace = monitor.at("workspaces").at("elements").at(0);
    CHECK(workspace.at("floating_windows").contains("elements")); // Ring, not array
    const auto& window =
        workspace.at("containers").at("elements").at(0).at("windows").at("elements").at(0);
    CHECK(window.at("exe") == "chrome.exe");
    CHECK(window.at("class") == "Chrome_WidgetWin_1");
    // right/bottom are width/height (2880-wide monitor, 11 px gaps), not
    // edge coordinates.
    CHECK(window.at("rect").at("right") == 2858);
    CHECK(window.at("rect").at("bottom") == 1682);
    CHECK(state.at("is_paused") == false);
}

TEST_CASE("recorded subscription notification parses as a Socket event") {
    const auto payload = readFixture("notification-add-subscriber.json");
    const auto parsed = json::parse(payload);
    // Untagged NotificationEvent: the Socket wrapper name never appears —
    // `event` is directly the adjacently tagged SocketMessage.
    const auto& event = parsed.at("event");
    CHECK(event.at("type") == "AddSubscriberSocketWithOptions");
    REQUIRE(event.at("content").is_array()); // tuple content
    CHECK(event.at("content").at(0) == "ybar-fixture.sock");
    CHECK(event.at("content").at(1).at("filter_state_changes") == true);

    const auto update = KomorebiProvider::parseNotification(payload);
    REQUIRE(update.has_value());
    CHECK(update->workspaceNames == "I\nII\nIII\nIV\nV\nVI\nVII");
    CHECK(update->focusedWorkspace == "I");
}

TEST_CASE("TogglePause notifications flip is_paused") {
    const auto onPayload = readFixture("notification-toggle-pause-on.json");
    const auto on = json::parse(onPayload);
    const auto off = json::parse(readFixture("notification-toggle-pause-off.json"));
    // Unit SocketMessage variant: {"type":"TogglePause"}, no content key.
    CHECK(on.at("event").at("type") == "TogglePause");
    CHECK_FALSE(on.at("event").contains("content"));
    CHECK(off.at("event").at("type") == "TogglePause");
    CHECK(on.at("state").at("is_paused") == true);
    CHECK(off.at("state").at("is_paused") == false);
    // A pause flip is still a full snapshot the workspace parse accepts.
    CHECK(KomorebiProvider::parseNotification(onPayload).has_value());
}

TEST_CASE("synthetic FocusChange notification parses") {
    // WindowManagerEvent is adjacently tagged with a (WinEvent, Window)
    // tuple content; the Window carries the wire quintet.
    const auto payload = readFixture("synthetic-focus-change.json");
    const auto parsed = json::parse(payload);
    CHECK(parsed.at("event").at("type") == "FocusChange");
    CHECK(parsed.at("event").at("content").at(0) == "SystemForeground");
    CHECK(parsed.at("event").at("content").at(1).at("exe") == "notepad.exe");

    const auto update = KomorebiProvider::parseNotification(payload);
    REQUIRE(update.has_value());
    CHECK(update->focusedWorkspace == "II");
    CHECK(update->focusedIndex == 2);
    CHECK(update->workspaceNames == "I\nII");
}

TEST_CASE("synthetic virtual-desktop notification's bare-string event parses") {
    // VirtualDesktopNotification has no tag: `event` arrives as a plain
    // string, not an object — the parser must not reject it.
    const auto payload = readFixture("synthetic-virtual-desktop.json");
    CHECK(json::parse(payload).at("event").is_string());
    const auto update = KomorebiProvider::parseNotification(payload);
    REQUIRE(update.has_value());
    CHECK(update->focusedWorkspace == "I");
    CHECK(update->workspacesChanged);
}

TEST_CASE("parse tolerates unknown fields and missing optionals") {
    const auto update =
        KomorebiProvider::parseNotification(readFixture("synthetic-tolerance.json"));
    REQUIRE(update.has_value());
    // Null and absent names fall back to the 1-based index string; missing
    // `focused` keys default to 0.
    CHECK(update->workspaceNames == "1\n2\nchat");
    CHECK(update->focusedWorkspace == "1");
    CHECK(update->focusedIndex == 1);
    CHECK(update->focusedMonitorIndex == 0);
    CHECK(update->workspacesChanged);
}

TEST_CASE("komorebi parse survives schema drift") {
    CHECK_FALSE(KomorebiProvider::parseNotification("not json").has_value());
    CHECK_FALSE(KomorebiProvider::parseNotification("{}").has_value());
    CHECK_FALSE(KomorebiProvider::parseNotification(R"({"state":{}})").has_value());
    // Out-of-range focused index: parsed, but flagged as not publishable.
    const auto outOfRange = KomorebiProvider::parseNotification(
        R"({"monitors":{"elements":[{"workspaces":{"elements":[],"focused":3}}],"focused":0}})");
    REQUIRE(outOfRange.has_value());
    CHECK_FALSE(outOfRange->workspacesChanged);
}
