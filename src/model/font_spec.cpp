#include "model/font_spec.h"

#include <array>
#include <charconv>
#include <cstdio>

namespace ybar::model {

bool FontSpec::apply(std::string_view spec) {
    // Split on ':' KEEPING empty components (reference behavior).
    std::array<std::string_view, 3> parts{};
    std::size_t count = 0;
    std::size_t start = 0;
    for (std::size_t i = 0; i <= spec.size() && count < 3; ++i) {
        if (i == spec.size() || spec[i] == ':') {
            parts[count++] = spec.substr(start, i - start);
            start = i + 1;
        }
    }
    if (count > 0 && !parts[0].empty()) family = std::string(parts[0]);
    if (count > 1 && !parts[1].empty()) style = std::string(parts[1]);
    if (count > 2 && !parts[2].empty()) {
        double parsed = 0;
        const auto* begin = parts[2].data();
        const auto* end = begin + parts[2].size();
        const auto [ptr, ec] = std::from_chars(begin, end, parsed);
        if (ec != std::errc() || ptr != end || parsed <= 0) return false;
        size = parsed;
    }
    return true;
}

std::string FontSpec::serialize() const {
    char buffer[256];
    std::snprintf(buffer, sizeof(buffer), "%s:%s:%.1f", family.c_str(), style.c_str(), size);
    return buffer;
}

} // namespace ybar::model
