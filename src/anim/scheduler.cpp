#include "anim/scheduler.h"

#include <vector>

namespace ybar::anim {

namespace {

AnimValue lerpValue(const AnimValue& from, const AnimValue& to, double t) {
    if (std::holds_alternative<double>(from)) {
        const double a = std::get<double>(from);
        const double b = std::get<double>(to);
        return a + (b - a) * t;
    }
    return ybar::model::Color::lerp(std::get<ybar::model::Color>(from),
                                    std::get<ybar::model::Color>(to),
                                    static_cast<float>(t));
}

} // namespace

void AnimationScheduler::add(const std::string& key, Curve curve, int frames, AnimValue from,
                             AnimValue to, std::function<void(const AnimValue&)> apply,
                             std::function<void()> onComplete) {
    if (frames <= 0) { // zero-duration: direct set
        if (apply) apply(to);
        if (onComplete) onComplete();
        return;
    }
    // RETARGET: replace an in-flight animation, starting from its live value.
    if (const auto it = table_.find(key); it != table_.end()) from = it->second.current;
    Animation animation;
    animation.curve = curve;
    animation.duration = static_cast<double>(frames) / 60.0;
    animation.from = from;
    animation.current = from;
    animation.to = std::move(to);
    animation.apply = std::move(apply);
    animation.onComplete = std::move(onComplete);
    table_[key] = std::move(animation);
}

void AnimationScheduler::cancel(const std::string& key) { table_.erase(key); }

void AnimationScheduler::cancelPrefix(const std::string& prefix) {
    for (auto it = table_.begin(); it != table_.end();) {
        if (it->first.rfind(prefix, 0) == 0) it = table_.erase(it);
        else ++it;
    }
}

void AnimationScheduler::cancelAll() { table_.clear(); }

bool AnimationScheduler::tick(double now) {
    std::vector<std::function<void()>> completions;
    for (auto it = table_.begin(); it != table_.end();) {
        auto& animation = it->second;
        if (animation.startTime < 0) animation.startTime = now;
        const double t = animation.duration > 0
                             ? (now - animation.startTime) / animation.duration
                             : 1.0;
        if (t >= 1.0) {
            if (animation.apply) animation.apply(animation.to); // exact final value
            if (animation.onComplete) completions.push_back(std::move(animation.onComplete));
            it = table_.erase(it);
            continue;
        }
        animation.current = lerpValue(animation.from, animation.to, apply(animation.curve, t));
        if (animation.apply) animation.apply(animation.current);
        ++it;
    }
    for (auto& complete : completions) complete();
    return !table_.empty();
}

} // namespace ybar::anim
