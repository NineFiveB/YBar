// Animation scheduler (spec section 3.8): keyed table with RETARGET
// semantics — a new animation on an animating key replaces it, starting from
// the current live value (YBar's deliberate divergence from sketchybar
// queue-chaining). Durations are frames-at-60Hz (= frames/60 wall seconds at
// any refresh rate); colors lerp in linear light; onComplete fires only on
// natural completion, never on cancel.

#pragma once

#include <functional>
#include <string>
#include <unordered_map>
#include <variant>

#include "anim/curves.h"
#include "model/color.h"

namespace ybar::anim {

using AnimValue = std::variant<double, ybar::model::Color>;

class AnimationScheduler {
public:
    // Keys are "item.<id>.<dotted path>" / "bar.<key>".
    void add(const std::string& key, Curve curve, int frames, AnimValue from, AnimValue to,
             std::function<void(const AnimValue&)> apply,
             std::function<void()> onComplete = {});

    // Direct set on an animating key cancels it (no onComplete).
    void cancel(const std::string& key);
    void cancelPrefix(const std::string& prefix);
    void cancelAll();

    // Advances all animations to `now` (monotonic seconds). Returns true
    // while animations remain; the caller re-renders after each tick.
    bool tick(double now);

    bool active() const { return !table_.empty(); }

private:
    struct Animation {
        Curve curve;
        double duration = 0;
        double startTime = -1; // lazy-armed on first tick
        AnimValue from;
        AnimValue to;
        std::function<void(const AnimValue&)> apply;
        std::function<void()> onComplete;
        AnimValue current; // live value for retargeting
    };
    std::unordered_map<std::string, Animation> table_;
};

} // namespace ybar::anim
