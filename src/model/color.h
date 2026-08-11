// 0xAARRGGBB color, straight-alpha sRGB (docs/WINDOWS-PORT.md, section 3.3).
// Parsing accepts "0x"-prefixed hex or a plain decimal u32 — nothing else
// ("#ffffff" and named colors are rejected, reference behavior). --query
// serializes as lowercase "0x%08x". Color animation lerps in linear light.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>

namespace ybar::model {

struct Color {
    std::uint32_t argb = 0;

    static std::optional<Color> parse(std::string_view text);

    std::string hex() const; // lowercase "0x%08x"

    // Straight-alpha sRGB components, 0..1.
    float a() const { return static_cast<float>((argb >> 24) & 0xff) / 255.0f; }
    float r() const { return static_cast<float>((argb >> 16) & 0xff) / 255.0f; }
    float g() const { return static_cast<float>((argb >> 8) & 0xff) / 255.0f; }
    float b() const { return static_cast<float>(argb & 0xff) / 255.0f; }

    // Per-channel sRGB transfer function.
    static float toLinear(float srgb);
    static float toGamma(float linear);

    // Linear-light lerp of rgb, direct lerp of alpha; re-quantized to bytes.
    static Color lerp(Color from, Color to, float t);

    bool operator==(const Color&) const = default;
};

} // namespace ybar::model
