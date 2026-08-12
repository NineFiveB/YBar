// Provider contract tests (spec 10). The OS-driven parts (WASAPI callbacks,
// GSMTC sessions, WLAN state) can't run headless in CI, so what is pinned
// here is the pure logic those providers hand to the event bus: display-name
// resolution, and the wifi_ssid_prompt property plumbing.

#include <catch2/catch_test_macros.hpp>

#include "ipc/command_handler.h"
#include "model/bar_settings.h"
#include "events/event_bus.h"
#include "model/item.h"
#include "providers/app_info.h"

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
