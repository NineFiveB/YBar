// Value-typed styles mirroring the reference Item model (spec sections 3.3, 8).
// Defaults are parity-visible contracts — do not "improve" them.

#pragma once

#include <optional>
#include <string>

#include "model/color.h"
#include "model/font_spec.h"

namespace ybar::model {

struct ShadowStyle {
    bool drawing = false;
    Color color{0xff000000};
    double distance = 5;
    double angle = 30; // degrees; offset = (cos(a)*d, sin(a)*d), y flipped at render
    // Falloff width in points; 0 keeps the reference's hard offset copy.
    // A light colour at distance 0 with a blur makes this a GLOW instead --
    // same quad, same code path, and the only bloom this pipeline has.
    double blur = 0;

    bool operator==(const ShadowStyle&) const = default;
};

struct BackgroundStyle {
    bool drawing = false;
    Color color{0x00000000};
    std::optional<Color> gradientColor;
    double gradientAngle = 0;
    Color borderColor{0x00000000};
    double borderWidth = 0;
    double cornerRadius = 0;
    double cornerExponent = 2; // squircle exponent, reserved (renders circular in v1)
    double height = 0;         // 0 = derived from content
    double paddingLeft = 0;
    double paddingRight = 0;
    double xOffset = 0;
    double yOffset = 0;
    bool glass = false;
    std::string imageSource;
    double imageScale = 1;
    bool imageDrawing = true;
    double clip = 0; // >= 0; punches an item-shaped hole in the bar background
    ShadowStyle shadow;

    bool operator==(const BackgroundStyle&) const = default;
};

struct TextPart {
    std::string string;
    bool drawing = true;
    Color color{0xffffffff};
    bool highlight = false;
    Color highlightColor{0x00000000};
    FontSpec font;
    double paddingLeft = 0;
    double paddingRight = 0;
    double yOffset = 0;       // positive-up (sketchybar convention)
    int scrollDuration = 100; // marquee cycle length, frames at ~60Hz
    int maxChars = 0;         // > 0 truncates to prefix + U+2026
    double customWidth = -1;  // -1 = dynamic (natural width)
    char align = 'l';         // l | c | r
    BackgroundStyle background;
    ShadowStyle shadow;

    // maxChars truncation, counting UTF-8 code points (approximating the
    // reference's Character count for the common cases).
    std::string displayString() const;

    bool operator==(const TextPart&) const = default;
};

enum class ItemPosition { Left, Right, Center, CenterLeft, CenterRight, Popup };

// left|l, right|r, center|c, q|center_left, e|center_right. Rejects "p"/popup
// (popup membership is created via the "popup.<host>" position grammar).
std::optional<ItemPosition> parsePosition(std::string_view token);

// Raw values used in --query output: left/right/center/q/e/p.
std::string_view positionRawValue(ItemPosition position);

enum class UpdatePolicy { On, Off, WhenShown };

} // namespace ybar::model
