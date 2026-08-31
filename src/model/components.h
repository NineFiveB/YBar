// Item components: graph, slider, gauge, image, popup (spec sections 3.3, 8).
// The reference keeps these as reference types that --clone deliberately does
// NOT copy; Item::clone() preserves that asymmetry.

#pragma once

#include <algorithm>
#include <deque>
#include <string>
#include <vector>

#include "model/color.h"
#include "model/style.h"

namespace ybar::model {

struct GraphState {
    int capacity = 60; // == width in points (sample_width = 1)
    // Pre-filled with `capacity` zeros: the reference ring always yields a
    // full-width series, so a fresh graph draws a flat baseline rather than a
    // growing partial polyline.
    std::deque<double> samples = std::deque<double>(60, 0.0);
    Color lineColor{0xffffffff};
    std::optional<Color> fillColor; // unset -> lineColor at 20% alpha
    double lineWidth = 1.0;

    // Resizes the ring in place (--add graph <width> after construction).
    void setCapacity(int newCapacity) {
        capacity = newCapacity;
        samples.assign(static_cast<std::size_t>(std::max(newCapacity, 0)), 0.0);
    }

    void push(double value) {
        samples.push_back(std::clamp(value, 0.0, 1.0));
        while (static_cast<int>(samples.size()) > capacity) samples.pop_front();
    }

    // Oldest -> newest.
    std::vector<double> ordered() const { return {samples.begin(), samples.end()}; }

    Color effectiveFillColor() const {
        if (fillColor) return *fillColor;
        const std::uint32_t alpha =
            static_cast<std::uint32_t>(((lineColor.argb >> 24) & 0xff) * 0.2 + 0.5);
        return Color{(alpha << 24) | (lineColor.argb & 0x00ffffff)};
    }
};

struct SliderState {
    double percentage = 0; // 0..100; sets are ignored while isDragged
    double width = 100;
    Color highlightColor{0xffffffff};
    BackgroundStyle background = [] {
        BackgroundStyle style;
        style.drawing = true;
        style.color = Color{0x4dffffff};
        style.height = 6;
        style.cornerRadius = 3;
        return style;
    }();
    TextPart knob;
    bool isDragged = false;
    // A slider used as a READ-ONLY meter (a battery/level gauge) must not be
    // scrubbable: without this, every mouse-down rewrites `percentage` from
    // the pointer x, so a click shows a fabricated value until something
    // re-applies the real one. interactive=off keeps the visual and drops the
    // drag machinery (no press/drag/PERCENTAGE, sets always apply).
    bool interactive = true;
};

struct GaugeState {
    double percentage = 0; // 0..100
    double size = 84;      // dial diameter, min 8
    double thickness = 8;  // ring width, min 1
    Color color{0xffffffff};
    Color trackColor{0x40ffffff};
};

struct ImageState {
    std::string source; // "spinner[.deg]" | "sf.<name>" | "app.<Name>" | "exe.<path>" | file path
    bool drawing = true;
    double size = 18; // square points, min 1
    double paddingLeft = 0;
    double paddingRight = 0;
    double rotation = 0; // clockwise degrees
    char align = 'l';    // 'r' = image trails the label

    double advance() const {
        return (drawing && !source.empty()) ? size + paddingLeft + paddingRight : 0;
    }
};

struct PopupState {
    bool isOpen = false;
    bool horizontal = false;
    double wrapWidth = 0;  // > 0 enables flow-wrap layout
    bool autoClose = true; // YBar extension over sketchybar
    char align = 'l';
    double blurRadius = 0;
    double cellHeight = 0; // 0 = per-row natural
    double yOffset = 0;
    BackgroundStyle background = [] {
        BackgroundStyle style;
        style.drawing = true;
        style.color = Color{0xee222222};
        style.cornerRadius = 8;
        return style;
    }();
};

} // namespace ybar::model
