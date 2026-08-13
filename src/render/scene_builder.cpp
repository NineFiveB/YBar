#include "render/scene_builder.h"

#include <cmath>
#include <optional>

namespace ybar::render {

using ybar::model::BackgroundStyle;
using ybar::model::Color;
using ybar::model::Item;
using ybar::model::Point;
using ybar::model::Rect;
using ybar::model::TextPart;

namespace {

// Authored color bytes are sRGB; the swap chain's sRGB RTV re-encodes on
// store, so shader inputs must be LINEAR or every color comes out
// gamma-brightened (0x06 painted as ~0x2b — caught live when the bar went
// dark). Exact sRGB EOTF, matching the reference's YColor.toLinear; alpha
// is coverage, not color, and stays untouched.
float srgbToLinear(float c) {
    return c <= 0.04045f ? c / 12.92f : std::pow((c + 0.055f) / 1.055f, 2.4f);
}

Float4 colorOf(Color color) {
    return {srgbToLinear(color.r()), srgbToLinear(color.g()), srgbToLinear(color.b()),
            color.a()};
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
// Clips a glyph quad to `clip` (device px) and remaps its UVs proportionally
// — exact for axis-aligned quads, no scissor or stencil (spec 3.9). Returns
// false when the glyph lies fully outside.
bool clipGlyph(GlyphInstance& glyph, const Float2& clipMin, const Float2& clipMax) {
    const float left = glyph.origin.x;
    const float top = glyph.origin.y;
    const float right = left + glyph.size.x;
    const float bottom = top + glyph.size.y;
    const float newLeft = std::max(left, clipMin.x);
    const float newTop = std::max(top, clipMin.y);
    const float newRight = std::min(right, clipMax.x);
    const float newBottom = std::min(bottom, clipMax.y);
    if (newRight <= newLeft || newBottom <= newTop) return false;
    if (newLeft == left && newTop == top && newRight == right && newBottom == bottom)
        return true; // fully inside

    const float uScale = glyph.size.x > 0 ? glyph.uvSize.x / glyph.size.x : 0;
    const float vScale = glyph.size.y > 0 ? glyph.uvSize.y / glyph.size.y : 0;
    glyph.uvOrigin = {glyph.uvOrigin.x + (newLeft - left) * uScale,
                      glyph.uvOrigin.y + (newTop - top) * vScale};
    glyph.uvSize = {(newRight - newLeft) * uScale, (newBottom - newTop) * vScale};
    glyph.origin = {newLeft, newTop};
    glyph.size = {newRight - newLeft, newBottom - newTop};
    return true;
}

void emitText(DisplayList& list, const ShapedLine& line, double penX, double baselineY,
              Color color, double scale, GlyphAtlas& atlas,
              const Rect* clipRect = nullptr) {
    const Float4 tint = colorOf(color);
    Float2 clipMin{}, clipMax{};
    if (clipRect) {
        clipMin = {static_cast<float>(snap(clipRect->minX(), scale)),
                   static_cast<float>(snap(clipRect->minY(), scale))};
        clipMax = {static_cast<float>(snap(clipRect->maxX(), scale)),
                   static_cast<float>(snap(clipRect->maxY(), scale))};
    }
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
            if (clipRect && !clipGlyph(glyph, clipMin, clipMax)) continue;
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
    // Full dial size, centered on the row's center line (reference math —
    // the row is sized to the dial by popup layout; clamping here shrank
    // dials wherever the box happened to be shorter).
    const double diameter = gauge.size;
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

// Inline image component: a color-page quad, vertically centered in the
// content box. penX advances by the full advance (padding + size).
void emitImage(DisplayList& list, const ybar::model::ImageState& image, double& penX,
               const Rect& contentBox, double scale, GlyphAtlas& atlas) {
    if (!image.drawing || image.source.empty()) return;
    const int sizePx = static_cast<int>(std::round(image.size * scale));
    const auto entry = atlas.image(image.source, sizePx);
    penX += image.paddingLeft;
    if (entry) {
        GlyphInstance quad;
        quad.origin = {static_cast<float>(snap(penX, scale)),
                       static_cast<float>(snap(contentBox.midY() - image.size / 2, scale))};
        quad.size = {static_cast<float>(entry->widthPx), static_cast<float>(entry->heightPx)};
        quad.uvOrigin = {entry->uvOriginX, entry->uvOriginY};
        quad.uvSize = {entry->uvSizeX, entry->uvSizeY};
        quad.color = {1, 1, 1, 1}; // color page carries its own pixels
        quad.flags |= kGlyphFlagColor;
        list.glyphs.push_back(quad);
    }
    penX += image.size + image.paddingRight;
}

// One text part inside the item's content box. penX advances past the part.
// Intersection for stacked clips (part slot ∩ item box); nullopt = empty.
std::optional<Rect> intersectRects(const Rect& a, const Rect& b) {
    const double x0 = std::max(a.x, b.x);
    const double y0 = std::max(a.y, b.y);
    const double x1 = std::min(a.maxX(), b.maxX());
    const double y1 = std::min(a.maxY(), b.maxY());
    if (x1 <= x0 || y1 <= y0) return std::nullopt;
    return Rect{x0, y0, x1 - x0, y1 - y0};
}

void emitPart(DisplayList& list, const TextPart& part, double& penX, const Rect& contentBox,
              double scale, FontCache& fonts, GlyphAtlas& atlas, bool isIcon = false,
              bool scrollTexts = false, double clock = 0, bool* wantsMarquee = nullptr,
              const Rect* itemClip = nullptr) {
    if (!part.drawing) return;
    const auto& line = fonts.shape(part.displayString(), part.font);

    const double natural = part.paddingLeft + line.width + part.paddingRight;
    const double slotWidth = part.customWidth >= 0 ? part.customWidth : natural;
    double textX = penX + part.paddingLeft;
    if (part.customWidth >= 0) {
        // Alignment slack inside the fixed slot (unclamped, spec 3.9).
        const double slack = part.customWidth - natural;
        if (part.align == 'c') textX += slack / 2;
        else if (part.align == 'r') textX += slack;
    }

    // Vertical placement (spec 3.9): single-glyph icons center on INK;
    // everything else centers on the em box. y_offset is positive-up.
    const double centerY = contentBox.midY() - part.yOffset;
    const double baselineY = (isIcon && line.glyphCount == 1 && line.inkMaxY > line.inkMinY)
                                 ? centerY + (line.inkMinY + line.inkMaxY) / 2
                                 : centerY + (line.ascent - line.descent) / 2;

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

    // Fixed-width slots clip their content; an overflowing one with
    // scroll_texts becomes a marquee (spec 3.9). A fixed-width ITEM clips
    // everything to its content box on top (the width-animation reveal) —
    // the two clips stack by intersection, matching the reference emitText.
    const bool overflows = part.customWidth >= 0 && natural > part.customWidth;
    std::optional<Rect> effectiveClip;
    if (part.customWidth >= 0) {
        const Rect slot{penX, contentBox.y, slotWidth, contentBox.height};
        effectiveClip = itemClip ? intersectRects(slot, *itemClip) : slot;
        if (!effectiveClip) return; // empty slot ∩ box: nothing can draw
    } else if (itemClip) {
        effectiveClip = *itemClip;
    }
    const Rect* clipPtr = effectiveClip ? &*effectiveClip : nullptr;
    const Color inkColor = part.highlight ? part.highlightColor : part.color;

    if (overflows && scrollTexts && line.inkWidth > 0) {
        // cycle = ink + 24pt gap; speed = cycle / (scroll_duration / 60 s).
        // The line is drawn twice, one cycle apart, clipped to the slot.
        const double cycle = line.inkWidth + 24;
        const double seconds = std::max(part.scrollDuration, 1) / 60.0;
        const double offset = std::fmod(clock * (cycle / seconds), cycle);
        const double start = penX + part.paddingLeft - offset;
        emitText(list, line, start - line.inkMinX, baselineY, inkColor, scale, atlas, clipPtr);
        emitText(list, line, start + cycle - line.inkMinX, baselineY, inkColor, scale, atlas,
                 clipPtr);
        if (wantsMarquee) *wantsMarquee = true;
    } else {
        const Rect* clip = clipPtr;
        // Text shadow: the same line drawn offset underneath, in the shadow
        // color (hard offset, no blur — spec 3.9).
        if (part.shadow.drawing) {
            const double radians = part.shadow.angle * 3.14159265358979323846 / 180.0;
            emitText(list, line,
                     textX - line.inkMinX + std::cos(radians) * part.shadow.distance,
                     baselineY - std::sin(radians) * part.shadow.distance, part.shadow.color,
                     scale, atlas, clip);
        }
        emitText(list, line, textX - line.inkMinX, baselineY, inkColor, scale, atlas, clip);
    }
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

    // 0) background.clip cutouts: items punch item-shaped rounded holes in
    // the BAR background only, max 16 per frame (spec 3.9).
    for (const auto& item : items) {
        if (list.holes.size() >= DisplayList::kMaxHoles) break;
        if (!item->drawing || item->background.clip <= 0) continue;
        if (item->kind == ybar::model::ItemKind::Bracket) continue;
        const auto boxIt = contentBoxes.find(item->id);
        if (boxIt == contentBoxes.end() || boxIt->second.width <= 0) continue;
        const Rect& box = boxIt->second;
        const double height = item->background.height > 0 ? item->background.height
                                                          : box.height;
        const Rect holeRect{box.x - item->background.paddingLeft,
                            box.midY() - height / 2 - item->yOffset,
                            box.width + item->background.paddingLeft +
                                item->background.paddingRight,
                            height};
        Hole hole;
        Float2 origin{}, size{};
        snappedRect(holeRect, scale, origin, size);
        hole.origin = origin;
        hole.size = size;
        hole.radius = static_cast<float>(item->background.cornerRadius * scale);
        list.holes.push_back(hole);
    }

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
        auto quad = backgroundQuad(barBg, Rect{0, 0, params.barWidth, params.barHeight}, scale);
        if (!list.holes.empty()) quad.flags |= kQuadFlagHoles;
        list.quads.push_back(quad);
    }

    // 2) Bracket backgrounds, painted BEFORE members so paint order replaces
    // z-order (spec 3.9). Frames are computed post-layout by the caller.
    for (const auto& item : items) {
        if (!item->drawing || item->kind != ybar::model::ItemKind::Bracket) continue;
        if (item->frame.isZero() || !item->background.drawing) continue;
        const double height = item->background.height > 0 ? item->background.height
                                                          : params.barHeight - 4;
        const Rect box{item->frame.x, item->frame.midY() - height / 2 - item->yOffset,
                       item->frame.width, height};
        list.quads.push_back(backgroundQuad(item->background, box, scale));
    }

    // 3) Per item (paint order: shadow -> background -> icon -> label; spec 3.9).
    for (const auto& item : items) {
        if (!item->drawing || item->kind == ybar::model::ItemKind::Bracket) continue;
        if (item->position == ybar::model::ItemPosition::Popup) continue;
        const auto boxIt = contentBoxes.find(item->id);
        if (boxIt == contentBoxes.end() || boxIt->second.isZero()) continue;
        emitItem(list, *item, boxIt->second, scale, fonts, atlas, params.clock);
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
              FontCache& fonts, GlyphAtlas& atlas, double clock) {
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
    // Fixed-width slot semantics (spec 3.9): a customWidth item aligns its
    // natural content inside the slot — UNCLAMPED, so overflow anchors per
    // align exactly like the reference's emit-side slack. Without this the
    // content renders flush left and slider hit-mapping (which mirrors the
    // reference math) disagrees with the pixels by the slack.
    if (item.customWidth >= 0) {
        ybar::model::MeasuredContent measured;
        const auto& iconLine = fonts.shape(item.icon.displayString(), item.icon.font);
        const auto& labelLine = fonts.shape(item.label.displayString(), item.label.font);
        measured.icon = {iconLine.width, iconLine.measuredHeight()};
        measured.label = {labelLine.width, labelLine.measuredHeight()};
        const double slack = item.customWidth - ybar::model::naturalLength(item, measured);
        if (item.align == 'c') penX += slack / 2;
        else if (item.align == 'r') penX += slack;
    }
    // A fixed-width ITEM clips its text to the content box: width animations
    // must be a clipped reveal, never overprint neighbors (reference rule).
    const Rect* itemClip = item.customWidth >= 0 ? &contentBox : nullptr;
    // Paint order: image (unless align=r) -> icon -> components -> label ->
    // image (align=r), per spec 3.9.
    const bool imageTrails = item.image && item.image->align == 'r';
    if (item.image && !imageTrails) emitImage(list, *item.image, penX, adjusted, scale, atlas);
    emitPart(list, item.icon, penX, adjusted, scale, fonts, atlas, /*isIcon=*/true,
             item.scrollTexts, clock, &list.hasMarquee, itemClip);

    if (item.graph) {
        const bool rightToLeft = item.position == ybar::model::ItemPosition::Right ||
                                 item.position == ybar::model::ItemPosition::CenterLeft;
        // Reference box math (SceneBuilder.emitGraph): the graph fills the
        // background PILL height, centered on the item's center line — not
        // the full content box, which is bar-height and would hang the graph
        // out of a shorter pill.
        const double height = item.background.height > 0 ? item.background.height
                                                         : adjusted.height - 2;
        const double centerY = adjusted.y + adjusted.height / 2;
        const Rect box{penX, centerY - height / 2,
                       static_cast<double>(item.graph->capacity), height};
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
    if (!item.gauge)
        emitPart(list, item.label, penX, adjusted, scale, fonts, atlas, /*isIcon=*/false,
                 item.scrollTexts, clock, &list.hasMarquee, itemClip);
    if (imageTrails) emitImage(list, *item.image, penX, adjusted, scale, atlas);
}

} // namespace ybar::render
