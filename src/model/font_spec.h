// "Family:Style:Size" font specification (docs/WINDOWS-PORT.md section 3.3).
// Partial application is a contract: an empty component preserves the current
// value (":Bold:" changes only the style). Serialized as "Family:Style:%.1f".

#pragma once

#include <string>
#include <string_view>

namespace ybar::model {

struct FontSpec {
    std::string family; // empty = system font (Segoe UI Variable on Windows)
    std::string style;
    double size = 14.0;

    // Applies "Family:Style:Size" on top of the current values. Returns false
    // when a non-empty size component is not a number.
    bool apply(std::string_view spec);

    std::string serialize() const; // "Family:Style:%.1f"

    bool operator==(const FontSpec&) const = default;
};

} // namespace ybar::model
