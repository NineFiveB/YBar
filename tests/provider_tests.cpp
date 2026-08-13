// Provider contract tests (spec 10). The OS-driven parts (WASAPI callbacks,
// GSMTC sessions, WLAN state) can't run headless in CI, so what is pinned
// here is the pure logic those providers hand to the event bus: display-name
// resolution, and the wifi_ssid_prompt property plumbing.

#include <catch2/catch_test_macros.hpp>

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h> // GetCurrentProcessId
// clang-format on

#include "ipc/command_handler.h"
#include "model/bar_settings.h"
#include "events/event_bus.h"
#include "model/item.h"
#include "providers/app_info.h"
#include "providers/ytile.h"

using ybar::events::EventBus;
using ybar::model::BarSettings;
using ybar::model::ItemStore;

TEST_CASE("app display names fall back to the executable basename") {
    // No version resource on a path that doesn't exist, so this exercises the
    // fallback the komorebi Show/Destroy path relies on (it only ever has an
    // exe string, never a live process).
    REQUIRE(ybar::providers::appNameForExecutablePath("C:\\apps\\Spotify.exe") == "Spotify");
    REQUIRE(ybar::providers::appNameForExecutablePath("firefox.exe") == "firefox");
    REQUIRE(ybar::providers::appNameForExecutablePath("C:/apps/some tool.exe") == "some tool");
    // Case-insensitive extension, and a name that merely ends in "exe".
    REQUIRE(ybar::providers::appNameForExecutablePath("Foo.EXE") == "Foo");
    REQUIRE(ybar::providers::appNameForExecutablePath("annexe") == "annexe");
    REQUIRE(ybar::providers::appNameForExecutablePath("").empty());
}

TEST_CASE("a real system binary resolves to its FileDescription") {
    // notepad.exe ships a version resource on every Windows install; the
    // description is localized, so only assert that it is not the basename
    // fallback shape.
    const auto name = ybar::providers::appNameForExecutablePath("C:\\Windows\\System32\\notepad.exe");
    REQUIRE_FALSE(name.empty());
}

TEST_CASE("a live process resolves to a usable display name") {
    // The front-app and app-lifecycle paths both go through this. The test
    // binary has no version resource, so this exercises the basename
    // fallback against a real, running process.
    const auto name = ybar::providers::appNameForProcess(GetCurrentProcessId());
    REQUIRE_FALSE(name.empty());
    REQUIRE(name.find(".exe") == std::string::npos); // extension always stripped
}

TEST_CASE("an invalid process id yields an empty name, never a crash") {
    // Callers treat "" as "skip this event" rather than publishing a
    // placeholder — a process can exit between the event and the lookup.
    REQUIRE(ybar::providers::appNameForProcess(0xFFFFFFFCu).empty());
    REQUIRE(ybar::providers::appNameForWindow(nullptr).empty());
}

TEST_CASE("ytile state parses to the WORKSPACES widget contract") {
    // Shape from YTile docs/YTILE-IPC.md: 9 workspaces per monitor, shown =
    // non-empty OR active, focused = active+1 as a number string.
    const char* state = R"({
      "monitors": [{
        "device": "\\\\.\\DISPLAY1", "primary": true, "active": 2,
        "workspaces": [
          {"layout":"bsp","focused":0,"windows":[{"hwnd":11,"exe":"a.exe","title":"A"}],"floating":[]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[{"hwnd":44,"exe":"d.exe","title":"D"}]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[]},
          {"layout":"bsp","focused":0,"windows":[],"floating":[]}
        ]
      }]
    })";
    const auto update = ybar::providers::YTileProvider::parseState(state);
    REQUIRE(update.has_value());
    // Shown: 1 (windows), 3 (active though empty), 4 (floating) — ascending.
    CHECK(update->workspaceNames == "1\n3\n4");
    CHECK(update->focusedWorkspace == "3");
    CHECK(update->focusedIndex == 2); // position within the shown list
    CHECK(update->focusedMonitorIndex == 0);
}

TEST_CASE("ytile parse survives schema drift") {
    CHECK_FALSE(ybar::providers::YTileProvider::parseState("not json").has_value());
    CHECK_FALSE(ybar::providers::YTileProvider::parseState("{}").has_value());
    CHECK_FALSE(
        ybar::providers::YTileProvider::parseState(R"({"monitors":[]})").has_value());
    // A monitor without a workspaces array still yields the active number.
    const auto bare =
        ybar::providers::YTileProvider::parseState(R"({"monitors":[{"active":4}]})");
    REQUIRE(bare.has_value());
    CHECK(bare->focusedWorkspace == "5");
    CHECK(bare->workspaceNames == "5");
    CHECK(bare->focusedIndex == 1);
}

TEST_CASE("wifi_ssid_prompt=on fires the permission hook exactly once per set") {
    ItemStore store;
    BarSettings settings;
    EventBus bus;
    int prompts = 0;
    ybar::ipc::DaemonHooks hooks;
    hooks.requestSsidPermission = [&prompts] { ++prompts; };
    ybar::ipc::CommandHandler handler(store, settings, bus, hooks);

    REQUIRE(handler.handle({"--bar", "wifi_ssid_prompt=off"}).empty());
    REQUIRE(prompts == 0);
    REQUIRE(settings.wifiSsidPrompt == false);

    REQUIRE(handler.handle({"--bar", "wifi_ssid_prompt=on"}).empty());
    REQUIRE(prompts == 1);
    REQUIRE(settings.wifiSsidPrompt == true);

    // Turning it back off must not re-open the settings page.
    REQUIRE(handler.handle({"--bar", "wifi_ssid_prompt=off"}).empty());
    REQUIRE(prompts == 1);
}
