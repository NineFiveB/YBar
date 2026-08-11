// The dotted property-path grammar — the primary sketchybar-compat surface
// (docs/WINDOWS-PORT.md section 3.3). Every path, accepted-and-ignored key,
// default, auto-enable rule, and error string is contract, ported from the
// reference PropertySetter.
//
// Animation integration: sets are direct for now; the AnimationScheduler hook
// point is the single set() entry, to be wired in the animation slice.

#pragma once

#include <optional>
#include <string>
#include <string_view>

#include "model/item.h"

namespace ybar::model {

class PropertySetter {
public:
    // nullopt = success. Errors begin "[!]" (invalid value) or "[?]" (unknown
    // path/warning) — the exact prefixes are client-visible contract.
    static std::optional<std::string> set(Item& item, std::string_view path,
                                          const std::string& value);

    // Bool grammar: on/true/yes/1 | off/false/no/0, case-insensitive.
    static std::optional<bool> parseBool(std::string_view value);
};

} // namespace ybar::model
