// The dotted property-path grammar — the primary sketchybar-compat surface
// (docs/WINDOWS-PORT.md section 3.3). Every path, accepted-and-ignored key,
// default, auto-enable rule, and error string is contract, ported from the
// reference PropertySetter.
//
#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "anim/scheduler.h"
#include "model/item.h"

namespace ybar::model {

class PropertySetter {
public:
    // Message-scoped --animate context (spec 3.8). frames == 0 means direct
    // sets that CANCEL in-flight animations on the same key. Single-threaded
    // by design (all sets run on the UI thread).
    struct AnimationContext {
        ybar::anim::AnimationScheduler* scheduler = nullptr;
        ybar::anim::Curve curve = ybar::anim::Curve::Linear;
        int frames = 0;
        int itemId = 0;
    };
    static void beginAnimation(const AnimationContext& context);
    static void endAnimation();

    // nullopt = success. Errors begin "[!]" (invalid value) or "[?]" (unknown
    // path/warning) — the exact prefixes are client-visible contract.
    static std::optional<std::string> set(Item& item, std::string_view path,
                                          const std::string& value);

    // Bool grammar: on/true/yes/1 | off/false/no/0, case-insensitive.
    static std::optional<bool> parseBool(std::string_view value);
};

} // namespace ybar::model
