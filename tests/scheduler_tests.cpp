// Animation scheduler contract tests (spec section 3.8): retarget semantics,
// frames-at-60Hz durations, exact final values, cancel-without-complete.

#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>

#include "anim/scheduler.h"

using namespace ybar::anim;
using ybar::model::Color;
using Catch::Matchers::WithinAbs;

TEST_CASE("animates a float over frames/60 seconds and lands exactly on target") {
    AnimationScheduler scheduler;
    double value = 0;
    bool completed = false;
    scheduler.add("k", Curve::Linear, 30, 0.0, 10.0,
                  [&](const AnimValue& v) { value = std::get<double>(v); },
                  [&] { completed = true; });
    REQUIRE(scheduler.active());

    CHECK(scheduler.tick(100.0)); // arms the start time
    CHECK(scheduler.tick(100.25)); // halfway through 0.5 s
    CHECK_THAT(value, WithinAbs(5.0, 0.01));
    CHECK_FALSE(scheduler.tick(100.6)); // past the end
    CHECK(value == 10.0);               // exact final value
    CHECK(completed);
    CHECK_FALSE(scheduler.active());
}

TEST_CASE("zero frames applies directly") {
    AnimationScheduler scheduler;
    double value = 0;
    scheduler.add("k", Curve::Linear, 0, 0.0, 7.0,
                  [&](const AnimValue& v) { value = std::get<double>(v); });
    CHECK(value == 7.0);
    CHECK_FALSE(scheduler.active());
}

TEST_CASE("same-key animation retargets from the live value, does not queue") {
    AnimationScheduler scheduler;
    double value = 0;
    scheduler.add("k", Curve::Linear, 60, 0.0, 100.0,
                  [&](const AnimValue& v) { value = std::get<double>(v); });
    scheduler.tick(0.0);
    scheduler.tick(0.5); // halfway: value == 50
    CHECK_THAT(value, WithinAbs(50.0, 0.1));

    // Retarget to 0 — must start from ~50, not chain after the first.
    scheduler.add("k", Curve::Linear, 30, /*from (ignored on retarget)*/ 999.0, 0.0,
                  [&](const AnimValue& v) { value = std::get<double>(v); });
    scheduler.tick(1.0);   // re-arms
    scheduler.tick(1.25);  // halfway of 0.5 s: 50 -> 0 midpoint = 25
    CHECK_THAT(value, WithinAbs(25.0, 0.5));
}

TEST_CASE("cancel drops the animation without firing onComplete") {
    AnimationScheduler scheduler;
    bool completed = false;
    scheduler.add("k", Curve::Linear, 60, 0.0, 1.0, {}, [&] { completed = true; });
    scheduler.cancel("k");
    CHECK_FALSE(scheduler.active());
    CHECK_FALSE(completed);
}

TEST_CASE("cancelPrefix clears an item's keys only") {
    AnimationScheduler scheduler;
    scheduler.add("item.1.width", Curve::Linear, 60, 0.0, 1.0, {});
    scheduler.add("item.1.label.color.alpha", Curve::Linear, 60, 0.0, 1.0, {});
    scheduler.add("item.2.width", Curve::Linear, 60, 0.0, 1.0, {});
    scheduler.cancelPrefix("item.1.");
    CHECK(scheduler.active());
    scheduler.cancelPrefix("item.2.");
    CHECK_FALSE(scheduler.active());
}

TEST_CASE("colors lerp in linear light through the scheduler") {
    AnimationScheduler scheduler;
    Color value{};
    scheduler.add("k", Curve::Linear, 30, Color{0xffff0000u}, Color{0xff00ff00u},
                  [&](const AnimValue& v) { value = std::get<Color>(v); });
    scheduler.tick(0.0);
    scheduler.tick(0.25); // midpoint
    // Linear-light midpoint is visibly brighter than the naive 0x80 per-byte mid.
    CHECK(((value.argb >> 16) & 0xff) > 0xb0);
    CHECK(((value.argb >> 8) & 0xff) > 0xb0);
}
