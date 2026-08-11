// Animation curve contract tests (CoreTests.swift parity) —
// docs/WINDOWS-PORT.md section 3.8.

#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>

#include "anim/curves.h"

using namespace ybar::anim;
using Catch::Matchers::WithinAbs;

namespace {
constexpr Curve kAll[] = {Curve::Linear, Curve::Quadratic, Curve::Sin,
                          Curve::Tanh,   Curve::Exp,       Curve::Circ,
                          Curve::Bounce, Curve::Overshoot};
}

TEST_CASE("every curve hits 0 at t=0 and 1 at t=1 within 0.05") {
    for (const auto curve : kAll) {
        CHECK_THAT(apply(curve, 0.0), WithinAbs(0.0, 0.05));
        CHECK_THAT(apply(curve, 1.0), WithinAbs(1.0, 0.05));
    }
}

TEST_CASE("curve names parse by first letter") {
    CHECK(parseCurve("linear") == Curve::Linear);
    CHECK(parseCurve("quadratic") == Curve::Quadratic);
    CHECK(parseCurve("q") == Curve::Quadratic);
    CHECK(parseCurve("sin") == Curve::Sin);
    CHECK(parseCurve("tanh") == Curve::Tanh);
    CHECK(parseCurve("exp") == Curve::Exp);
    CHECK(parseCurve("circ") == Curve::Circ);
    CHECK(parseCurve("bounce") == Curve::Bounce);
    CHECK(parseCurve("overshoot") == Curve::Overshoot);
}

TEST_CASE("unknown curve names fall back to linear") {
    CHECK(parseCurve("zigzag") == Curve::Linear);
    CHECK(parseCurve("") == Curve::Linear);
    CHECK(parseCurve("Linear") == Curve::Linear); // capital L is not l/q/s/t/e/c/b/o
}

TEST_CASE("overshoot exceeds 1 mid-flight (springy contract)") {
    bool exceeded = false;
    for (double t = 0.5; t < 1.0; t += 0.01) {
        if (apply(Curve::Overshoot, t) > 1.0) { exceeded = true; break; }
    }
    CHECK(exceeded);
}

TEST_CASE("quadratic is t squared") {
    CHECK_THAT(apply(Curve::Quadratic, 0.5), WithinAbs(0.25, 1e-9));
}
