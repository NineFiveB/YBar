#include "render/scene_builder.h"

#include <cmath>

namespace ybar::render {

using ybar::model::BackgroundStyle;
using ybar::model::Color;
using ybar::model::Item;
using ybar::model::Point;
using ybar::model::Rect;
using ybar::model::TextPart;

namespace {

Float4 colorOf(Color color) {
    return {color.r(), color.g(), color.b(), color.a()};
}

double snap(double value, double scale) { return std::round(value * scale); }

// Pixel snapping: origin and size rounded independently (spec 3.9).
void snappedRect(const Rect& rect, double scale, Float2& origin, Float2& size) {
    origin = {static_cast<float>(snap(rect.x, scale)), static_cast<float>(snap(rect.y, scale))};
    size = {static_cast<float>(snap(rect.width, scale)),
            static_cast<float>(snap(rect.height, scale))};
}

QuadInstance backgroundQuad(const BackgroundStyle& bg, const Rect& rect, double scale) {
    QuadInstance quad;
    snappedRect(rect, scale, quad.origin, quad.size);
    const auto radius = static_cast<float>(bg.cornerRadius * scale);
    quad.radii = {radius, radius, radius, radius};
    quad.fill = colorOf(bg.color);
    quad.borderColor = colorOf(bg.borderColor);
    quad.borderWidth = static_cast<float>(bg.borderWidth * scale);
    quad.cornerExponent = static_cast<float>(bg.cornerExponent);
    if (bg.gradientColor) {
        quad.fill2 = colorOf(*bg.gradientColor);
        const double radians = bg.gradientAngle * 3.14159265358979323846 / 180.0;
        quad.gradientDir = {static_cast<float>(std::cos(radians)),
                            static_cast<float>(std::sin(radians))};
        quad.flags |= kQuadFlagGradient;
    }
    if (bg.glass) quad.flags |= kQuadFlagGlass;
    return quad;
}

// Emits one shaped line at (penX, baselineY) in logical points, snapped to
// device pixels; returns nothing useful — glyphs go straight into the list.
void emitText(DisplayList& list, const ShapedLine& line, double penX, double baselineY,
              Color color, double scale, GlyphAtlas& atlas) {
    const Float4 tint = colorOf(color);
    for (const auto& run : line.runs) {
        // Pen walk: baseline origin + per-glyph advances/offsets (DIPs).
        double x = penX + run.baselineOriginX;
        const double baseY = baselineY + (run.baselineOriginY - line.baselineInLayout);
        for (std::size_t i = 0; i < run.glyphIds.size(); ++i) {
            const double glyphX = x + run.offsetsX[i];
            const double glyphY = baseY - run.offsetsY[i];
            x += run.advances[i];
            const auto entry = atlas.maskGlyph(run.fontFace, run.fontEmSize, run.glyphIds[i]);
            if (!entry) continue;
            GlyphInstance glyph;
            glyph.origin = {static_cast<float>(snap(glyphX, scale) + entry->bearingX),
                            static_cast<float>(snap(glyphY, scale) + entry->bearingY)};
            glyph.size = {static_cast<float>(entry->widthPx),
                          static_cast<float>(entry->heightPx)};
            glyph.uvOrigin = {entry->uvOriginX, entry->uvOriginY};
            glyph.uvSize = {entry->uvSizeX, entry->uvSizeY};
            glyph.color = tint;
            if (entry->color) glyph.flags |= kGlyphFlagColor;
            list.glyphs.push_back(glyph);
        }
    }
}

// Graph: per-segment fill quads down to the box baseline + constant-thickness
// polyline quads (spec 3.9). Sample x step = 1 point; y = maxY - sample*h.
void emitGraph(DisplayList& list, const ybar::model::GraphState& graph, const Rect& box,
               bool rightToLeft, double scale) {
    const auto samples = graph.ordered();
    if (samples.size() < 2) return;
    const auto lineColor = colorOf(graph.lineColor);
    const auto fillColor = colorOf(graph.effectiveFillColor());
    const double half = graph.lineWidth / 2.0;

    auto pointAt = [&](std::size_t i) {
        const double x = rightToLeft ? box.maxX() - static_cast<double>(i)
                                     : box.minX() + static_cast<double>(i);
        const double y = box.maxY() - samples[i] * box.height;
        return Point{x * scale, y * scale};
    };
    const float baseline = static_cast<float>(box.maxY() * scale);

    for (std::size_t i = 0; i + 1 < samples.size(); ++i) {
        const auto a = pointAt(i);
        const auto b = pointAt(i + 1);
        // Fill: two triangles down to the baseline.
        const ShapeVertex fillQuad[6] = {
            {{static_cast<float>(a.x), static_cast<float>(a.y)}, {}, fillColor},
            {{static_cast<float>(b.x), static_cast<float>(b.y)}, {}, fillColor},
            {{static_cast<float>(a.x), baseline}, {}, fillColor},
            {{static_cast<float>(b.x), static_cast<float>(b.y)}, {}, fillColor},
            {{static_cast<float>(b.x), baseline}, {}, fillColor},
            {{static_cast<float>(a.x), baseline}, {}, fillColor},
        };
        list.shapeVertices.insert(list.shapeVertices.end(), fillQuad, fillQuad + 6);
        // Line: a quad along the segment normal.
        const double dx = b.x - a.x;
        const double dy = b.y - a.y;
        const double length = std::sqrt(dx * dx + dy * dy);
        if (length <= 0) continue;
        const float nx = static_cast<float>(-dy / length * half * scale);
        const float ny = static_cast<float>(dx / length * half * scale);
        const auto ax = static_cast<float>(a.x);
        const auto ay = static_cast<float>(a.y);
        const auto bx = static_cast<float>(b.x);
        const auto by = static_cast<float>(b.y);
        const ShapeVertex lineQuad[6] = {
            {{ax - nx, ay - ny}, {}, lineColor}, {{ax + nx, ay + ny}, {}, lineColor},
            {{bx - nx, by - ny}, {}, lineColor}, {{ax + nx, ay + ny}, {}, lineColor},
            {{bx + nx, by + ny}, {}, lineColor}, {{bx - nx, by - ny}, {}, lineColor},
        };
        list.shapeVertices.insert(list.shapeVertices.end(), lineQuad, lineQuad + 6);
    }
}

void emitText(DisplayList& list, const ShapedLine& line, double penX, double baselineY,
              ybar::model::Color color, double scale, GlyphAtlas& atlas);

// Slider: rounded track, highlight over the left fraction, centered knob text.
void emitSlider(DisplayList& list, const ybar::model::SliderState& slider, const Rect& box,
                double scale, FontCache& fonts, GlyphAtlas& atlas) {
    const double trackHeight =
        slider.background.height > 0 ? slider.background.height : 6;
    const Rect track{box.x, box.midY() - trackHeight / 2, slider.width, trackHeight};
    if (slider.background.drawing) list.quads.push_back(backgroundQuad(slider.background, track, scale));

    const double fraction = std::clamp(slider.percentage / 100.0, 0.0, 1.0);
    if (fraction > 0) {
        ybar::model::BackgroundStyle highlight = slider.background;
        highlight.color = slider.highlightColor;
        highlight.gradientColor.reset();
        highlight.borderWidth = 0;
        list.quads.push_back(backgroundQuad(
            highlight, Rect{track.x, track.y, track.width * fraction, track.height}, scale));
    }
    if (slider.knob.drawing && !slider.knob.string.empty()) {
        const auto& line = fonts.shape(slider.knob.displayString(), slider.knob.font);
        // std::clamp's precondition fails when the knob is wider than the
        // track (hi < lo, UB): fall back to the track origin in that case.
        const double desired = track.x + track.width * fraction - line.width / 2;
        const double hi = track.maxX() - line.width;
        const double knobX = hi > track.x ? std::clamp(desired, track.x, hi) : track.x;
        const double baselineY =
            box.midY() - slider.knob.yOffset + (line.ascent - line.descent) / 2;
        emitText(list, line, knobX - line.inkMinX, baselineY, slider.knob.color, scale, atlas);
    }
}

// Gauge: 270-degree dial via the arc quad flag; the item LABEL renders
// centered inside the dial (spec 3.9).
void emitGauge(DisplayList& list, const ybar::model::Item& item, const Rect& box, double scale,
               FontCache& fonts, GlyphAtlas& atlas) {
    const auto& gauge = *item.gauge;
    const double diameter = std::min(gauge.size, box.height);
    const Rect dial{box.x + (box.width - diameter) / 2, box.midY() - diameter / 2, diameter,
                    diameter};
    QuadInstance quad;
    snappedRect(dial, scale, quad.origin, quad.size);
    const auto radius = static_cast<float>(diameter * scale / 2);
    quad.radii = {radius, radius, radius, radius}; // circle
    quad.fill = colorOf(gauge.trackColor);         // track
    quad.borderColor = colorOf(gauge.color);       // progress arc
    quad.borderWidth = static_cast<float>(gauge.thickness * scale);
    quad.gradientDir = {static_cast<float>(std::clamp(gauge.percentage / 100.0, 0.0, 1.0)), 0};
    quad.flags = kQuadFlagArc;
    list.quads.push_back(quad);

    if (item.label.drawing && !item.label.string.empty()) {
        const auto& line = fonts.shape(item.label.displayString(), item.label.font);
        const double baselineY =
            dial.midY() - item.label.yOffset + (line.ascent - line.descent) / 2;
        emitText(list, line, dial.midX() - line.width / 2 - line.inkMinX, baselineY,
                 item.label.color, scale, atlas);
    }
}

// One text part inside the item's content box. penX advances past the part.
void emitPart(DisplayList& list, const TextPart& part, double& penX, const Rect& contentBox,
              double scale, FontCache& fonts, GlyphAtlas& atlas) {
    if (!part.drawing) return;
    const auto& line = fonts.shape(part.displayString(), part.font);

    double slotWidth = part.customWidth >= 0
                           ? part.customWidth
                           : part.paddingLeft + line.width + part.paddingRight;
    double textX = penX + (part.customWidth >= 0 ? part.paddingLeft : part.paddingLeft);
    if (part.customWidth >= 0) {
        // Alignment slack inside the fixed slot (unclamped, spec 3.9).
        const double slack = part.customWidth - (part.paddingLeft + line.width + part.paddingRight);
        if (part.align == 'c') textX += slack / 2;
        else if (part.align == 'r') textX += slack;
    }

    // Em vertical centering: baseline = centerY + (ascent - descent) / 2,
    // y_offset positive-up (spec 3.9). Ink centering for single-glyph icons
    // arrives with the metric-parity pass.
    const double baselineY =
        contentBox.midY() - part.yOffset + (line.ascent - line.descent) / 2;

    if (part.background.drawing) {
        const double bgHeight = part.background.height > 0 ? part.background.height
                                                           : line.measuredHeight() + 4;
        const Rect bgRect{textX - part.background.paddingLeft + part.background.xOffset,
                          contentBox.midY() - bgHeight / 2 - part.background.yOffset,
                          line.width + part.background.paddingLeft +
                              part.background.paddingRight,
                          bgHeight};
        list.quads.push_back(backgroundQuad(part.background, bgRect, scale));
    }

    emitText(list, line, textX - line.inkMinX, baselineY, part.color, scale, atlas);
    penX += slotWidth;
}

} // namespace

DisplayList buildScene(const std::vector<std::unique_ptr<Item>>& items,
                       const std::unordered_map<int, Rect>& contentBoxes,
                       const ybar::model::BarSettings& settings, const SceneParams& params,
                       FontCache& fonts, GlyphAtlas& atlas) {
    DisplayList list;
    const double scale = params.scale;
    list.viewportSize = {static_cast<float>(snap(params.barWidth, scale)),
                         static_cast<float>(snap(params.barHeight, scale))};

    // 1) Bar background.
    {
        BackgroundStyle barBg;
        barBg.color = settings.color;
        barBg.gradientColor = settings.gradientColor;
        barBg.gradientAngle = settings.gradientAngle;
        barBg.borderColor = settings.borderColor;
        barBg.borderWidth = settings.borderWidth;
        barBg.cornerRadius = settings.cornerRadius;
        barBg.cornerExponent = settings.cornerExponent;
        barBg.glass = settings.glass;
        list.quads.push_back(
            backgroundQuad(barBg, Rect{0, 0, params.barWidth, params.barHeight}, scale));
    }

    // 2) Per item (paint order: shadow -> background -> icon -> label; spec 3.9).
    for (const auto& item : items) {
        if (!item->drawing || item->kind == ybar::model::ItemKind::Bracket) continue;
        if (item->position == ybar::model::ItemPosition::Popup) continue;
        const auto boxIt = contentBoxes.find(item->id);
        if (boxIt == contentBoxes.end() || boxIt->second.isZero()) continue;
        emitItem(list, *item, boxIt->second, scale, fonts, atlas);
    }

    return list;
}

DisplayList buildPopupScene(const std::vector<Item*>& members,
                            const std::vector<Rect>& contentBoxes,
                            const ybar::model::PopupState& popup, ybar::model::Size panelSize,
                            double scale, FontCache& fonts, GlyphAtlas& atlas) {
    DisplayList list;
    list.viewportSize = {static_cast<float>(snap(panelSize.width, scale)),
                         static_cast<float>(snap(panelSize.height, scale))};
    if (popup.background.drawing) {
        list.quads.push_back(backgroundQuad(
            popup.background, Rect{0, 0, panelSize.width, panelSize.height}, scale));
    }
    for (std::size_t i = 0; i < members.size() && i < contentBoxes.size(); ++i) {
        if (!members[i] || contentBoxes[i].isZero()) continue;
        emitItem(list, *members[i], contentBoxes[i], scale, fonts, atlas);
    }
    return list;
}

void emitItem(DisplayList& list, Item& item, const Rect& contentBox, double scale,
              FontCache& fonts, GlyphAtlas& atlas) {
    if (item.background.drawing) {
        const auto& iconLine = fonts.shape(item.icon.displayString(), item.icon.font);
        const auto& labelLine = fonts.shape(item.label.displayString(), item.label.font);
        const double contentHeight =
            std::max(item.icon.drawing ? iconLine.measuredHeight() : 0.0,
                     item.label.drawing ? labelLine.measuredHeight() : 0.0);
        const double bgHeight =
            item.background.height > 0
                ? item.background.height
                : std::min(contentBox.height, contentHeight + 8); // default rule (3.9)
        const Rect bgRect{contentBox.x - item.background.paddingLeft + item.background.xOffset,
                          contentBox.midY() - bgHeight / 2 - item.background.yOffset -
                              item.yOffset,
                          contentBox.width + item.background.paddingLeft +
                              item.background.paddingRight,
                          bgHeight};

        if (item.background.shadow.drawing) {
            const double radians =
                item.background.shadow.angle * 3.14159265358979323846 / 180.0;
            const double dx = std::cos(radians) * item.background.shadow.distance;
            const double dy = -std::sin(radians) * item.background.shadow.distance;
            BackgroundStyle shadowStyle = item.background;
            shadowStyle.color = item.background.shadow.color;
            shadowStyle.gradientColor.reset();
            shadowStyle.borderWidth = 0;
            shadowStyle.glass = false;
            list.quads.push_back(backgroundQuad(
                shadowStyle, Rect{bgRect.x + dx, bgRect.y + dy, bgRect.width, bgRect.height},
                scale)); // hard offset copy, no blur (spec 3.9)
        }
        list.quads.push_back(backgroundQuad(item.background, bgRect, scale));
    }

    Rect adjusted = contentBox;
    adjusted.y -= item.yOffset; // y_offset positive-up
    double penX = adjusted.x;
    emitPart(list, item.icon, penX, adjusted, scale, fonts, atlas);

    if (item.graph) {
        const bool rightToLeft = item.position == ybar::model::ItemPosition::Right ||
                                 item.position == ybar::model::ItemPosition::CenterLeft;
        const Rect box{penX, adjusted.y + 1, static_cast<double>(item.graph->capacity),
                       adjusted.height - 2};
        emitGraph(list, *item.graph, box, rightToLeft, scale);
        penX += item.graph->capacity;
    }
    if (item.slider) {
        emitSlider(list, *item.slider, Rect{penX, adjusted.y, item.slider->width,
                                            adjusted.height},
                   scale, fonts, atlas);
        penX += item.slider->width;
    }
    if (item.gauge) {
        emitGauge(list, item, Rect{penX, adjusted.y, item.gauge->size, adjusted.height}, scale,
                  fonts, atlas);
        penX += item.gauge->size;
    }
    if (item.image && item.image->drawing) penX += item.image->advance(); // WIC later
    if (!item.gauge) emitPart(list, item.label, penX, adjusted, scale, fonts, atlas);
}

} // namespace ybar::render
