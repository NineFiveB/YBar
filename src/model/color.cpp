#include "model/color.h"

#include <algorithm>
#include <cmath>
#include <cstdio>

namespace ybar::model {

namespace {

int hexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::uint8_t quantize(float channel) {
    const float clamped = std::clamp(channel, 0.0f, 1.0f);
    return static_cast<std::uint8_t>(std::lround(clamped * 255.0f));
}

} // namespace

std::optional<Color> Color::parse(std::string_view text) {
    if (text.size() >= 2 && (text.substr(0, 2) == "0x" || text.substr(0, 2) == "0X")) {
        const auto digits = text.substr(2);
        if (digits.empty() || digits.size() > 8) return std::nullopt;
        std::uint32_t value = 0;
        for (const char c : digits) {
            const int d = hexDigit(c);
            if (d < 0) return std::nullopt;
            value = (value << 4) | static_cast<std::uint32_t>(d);
        }
        return Color{value};
    }

    if (text.empty()) return std::nullopt;
    std::uint64_t value = 0;
    for (const char c : text) {
        if (c < '0' || c > '9') return std::nullopt;
        value = value * 10 + static_cast<std::uint64_t>(c - '0');
        if (value > 0xffffffffull) return std::nullopt;
    }
    return Color{static_cast<std::uint32_t>(value)};
}

std::string Color::hex() const {
    char buffer[11];
    std::snprintf(buffer, sizeof(buffer), "0x%08x", argb);
    return buffer;
}

float Color::toLinear(float srgb) {
    return srgb <= 0.04045f ? srgb / 12.92f
                            : std::pow((srgb + 0.055f) / 1.055f, 2.4f);
}

float Color::toGamma(float linear) {
    return linear <= 0.0031308f ? linear * 12.92f
                                : 1.055f * std::pow(linear, 1.0f / 2.4f) - 0.055f;
}

Color Color::lerp(Color from, Color to, float t) {
    const auto mix = [t](float x, float y) { return x + (y - x) * t; };
    const float a = mix(from.a(), to.a());
    const float r = toGamma(mix(toLinear(from.r()), toLinear(to.r())));
    const float g = toGamma(mix(toLinear(from.g()), toLinear(to.g())));
    const float b = toGamma(mix(toLinear(from.b()), toLinear(to.b())));
    return Color{(static_cast<std::uint32_t>(quantize(a)) << 24) |
                 (static_cast<std::uint32_t>(quantize(r)) << 16) |
                 (static_cast<std::uint32_t>(quantize(g)) << 8) |
                 static_cast<std::uint32_t>(quantize(b))};
}

} // namespace ybar::model
