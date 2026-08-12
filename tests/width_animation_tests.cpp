// --animate reach (spec 3.3, 3.8): bar-domain keys and the `width=dynamic`
// sentinel resolution. Both were previously direct-set only.

#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>

#include "anim/scheduler.h"
#include "events/event_bus.h"
#include "ipc/command_handler.h"
#include "model/bar_settings.h"
#include "model/item.h"

using Catch::Matchers::WithinAbs;
using ybar::events::EventBus;
using ybar::model::BarSettings;
using ybar::model::ItemStore;

namespace {

struct Fixture {
    ItemStore store;
    BarSettings settings;
    EventBus bus;
    ybar::anim::AnimationScheduler scheduler;
    std::unique_ptr<ybar::ipc::CommandHandler> handler;
    double naturalWidth = 100;

    Fixture() {
        ybar::ipc::DaemonHooks hooks;
        hooks.measureNaturalWidth = [this](const ybar::model::Item&) { return naturalWidth; };
        hooks.measureNaturalPartWidth = [this](const ybar::model::Item&, bool) {
            return naturalWidth;
        };
        handler = std::make_unique<ybar::ipc::CommandHandler>(store, settings, bus, hooks,
                                                              &scheduler);
    }

    // Runs the animation to completion; 60 frames = 1 s at 60 Hz.
    void runToCompletion() {
        scheduler.tick(1000.0); // arms
        scheduler.tick(1100.0); // far past any duration used here
    }
};

} // namespace

// Test names must not begin with "--": ctest passes the name to the Catch2
// binary, which would parse it as a command-line flag.
TEST_CASE("animate reaches bar float keys") {
    Fixture f;
    f.settings.height = 20;
    REQUIRE(f.handler->handle({"--animate", "linear", "60", "--bar", "height=50"}).empty());
    // Scheduled, not applied instantly.
    CHECK(f.settings.height == 20);
    CHECK(f.scheduler.active());
    f.runToCompletion();
    CHECK(f.settings.height == 50);
}

TEST_CASE("a direct bar set cancels an in-flight animation on the same key") {
    Fixture f;
    f.settings.height = 20;
    REQUIRE(f.handler->handle({"--animate", "linear", "60", "--bar", "height=50"}).empty());
    REQUIRE(f.scheduler.active());
    REQUIRE(f.handler->handle({"--bar", "height=33"}).empty());
    CHECK(f.settings.height == 33);
    CHECK_FALSE(f.scheduler.active());
    f.runToCompletion();
    CHECK(f.settings.height == 33); // the cancelled animation never lands
}

TEST_CASE("animate reaches bar color keys") {
    Fixture f;
    f.settings.color = ybar::model::Color{0xff000000};
    REQUIRE(f.handler->handle({"--animate", "linear", "60", "--bar", "color=0xffffffff"})
                .empty());
    CHECK(f.scheduler.active());
    f.runToCompletion();
    CHECK(f.settings.color.argb == 0xffffffff);
}

TEST_CASE("width=dynamic animates to the measured width, then restores the sentinel") {
    Fixture f;
    f.handler->handle({"--add", "item", "w", "left"});
    auto* item = f.store.find("w");
    REQUIRE(item);
    item->customWidth = 40;

    REQUIRE(f.handler->handle({"--animate", "linear", "60", "--set", "w", "width=dynamic"})
                .empty());
    CHECK(f.scheduler.active());
    // Mid-flight it holds a real number between the endpoints — never -1.
    f.scheduler.tick(1000.0);
    f.scheduler.tick(1000.5);
    CHECK(item->customWidth > 40);
    CHECK(item->customWidth < 100);
    // Completion hands the sentinel back so the item tracks content again.
    f.scheduler.tick(1002.0);
    CHECK(item->customWidth == -1);
}

TEST_CASE("animating away from dynamic seeds the start from the measured width") {
    Fixture f;
    f.handler->handle({"--add", "item", "w", "left"});
    auto* item = f.store.find("w");
    REQUIRE(item);
    REQUIRE(item->customWidth == -1); // dynamic by default

    REQUIRE(f.handler->handle({"--animate", "linear", "60", "--set", "w", "width=10"}).empty());
    // Seeded to 100 and animating down, rather than lerping up from -1.
    f.scheduler.tick(1000.0);
    f.scheduler.tick(1000.5);
    CHECK(item->customWidth < 100);
    CHECK(item->customWidth > 10);
    f.runToCompletion();
    CHECK(item->customWidth == 10);
}

TEST_CASE("without --animate, width=dynamic is still a plain direct set") {
    Fixture f;
    f.handler->handle({"--add", "item", "w", "left"});
    auto* item = f.store.find("w");
    REQUIRE(item);
    item->customWidth = 40;
    REQUIRE(f.handler->handle({"--set", "w", "width=dynamic"}).empty());
    CHECK(item->customWidth == -1);
    CHECK_FALSE(f.scheduler.active());
}
