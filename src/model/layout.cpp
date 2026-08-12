#include "model/layout.h"

namespace ybar::model {

double partAdvance(const TextPart& part, const Size& measured) {
    if (!part.drawing) return 0;
    if (part.customWidth >= 0) return part.customWidth;
    return part.paddingLeft + measured.width + part.paddingRight;
}

namespace {

// Component widths BETWEEN icon and label. The image sits outside this run
// (leading, or trailing the label when align=r) but its advance is part of
// the item's length either way.
double componentWidth(const Item& item) {
    double width = 0;
    if (item.image) width += item.image->advance();
    if (item.graph) width += item.graph->capacity; // capacity points, sample_width = 1
    if (item.slider) width += item.slider->width;
    if (item.gauge) width += item.gauge->size;
    return width;
}

} // namespace

double contentLength(const Item& item, const MeasuredContent& measured) {
    if (item.customWidth >= 0) return item.customWidth;
    return naturalLength(item, measured);
}

double naturalLength(const Item& item, const MeasuredContent& measured) {
    const double icon = partAdvance(item.icon, measured.icon);
    // A gauge's label renders centered inside the dial: zero flow width.
    const double label = item.gauge ? 0 : partAdvance(item.label, measured.label);
    return icon + componentWidth(item) + label;
}

std::unordered_map<int, Rect> layout(const std::vector<std::unique_ptr<Item>>& items,
                                     const LayoutSettings& settings, const Measure& measure) {
    std::unordered_map<int, Rect> boxes;
    const double height = settings.height;
    const double notchHalf = settings.notchWidth / 2;

    double leftX = settings.paddingLeft;
    double rightX = settings.width - settings.paddingRight;
    double qX = settings.width / 2 - notchHalf;
    double eX = settings.width / 2 + notchHalf;

    // Center pre-pass: the block is centered as a unit.
    double centerTotal = 0;
    for (const auto& item : items) {
        if (item->position != ItemPosition::Center) continue;
        if (!item->isVisibleInFlow() || item->kind == ItemKind::Bracket) continue;
        const auto m = measure(*item);
        centerTotal += item->paddingLeft + contentLength(*item, m) + item->paddingRight;
    }
    double centerX = (settings.width - centerTotal) / 2;

    for (const auto& item : items) {
        const bool inFlow = item->kind != ItemKind::Bracket &&
                            item->position != ItemPosition::Popup && item->isVisibleInFlow();
        if (!inFlow) {
            item->frame = Rect{};
            boxes[item->id] = Rect{};
            continue;
        }
        const auto m = measure(*item);
        const double len = contentLength(*item, m);
        Rect content;
        switch (item->position) {
            case ItemPosition::Left: {
                leftX += item->paddingLeft;
                content = Rect{leftX, 0, len, height};
                leftX += len + item->paddingRight;
                break;
            }
            case ItemPosition::Right: {
                rightX -= item->paddingRight + len;
                content = Rect{rightX, 0, len, height};
                rightX -= item->paddingLeft;
                break;
            }
            case ItemPosition::Center: {
                centerX += item->paddingLeft;
                content = Rect{centerX, 0, len, height};
                centerX += len + item->paddingRight;
                break;
            }
            case ItemPosition::CenterLeft: { // q: flows LEFT away from the notch
                qX -= item->paddingRight + len;
                content = Rect{qX, 0, len, height};
                qX -= item->paddingLeft;
                break;
            }
            case ItemPosition::CenterRight: { // e: flows RIGHT away from the notch
                eX += item->paddingLeft;
                content = Rect{eX, 0, len, height};
                eX += len + item->paddingRight;
                break;
            }
            case ItemPosition::Popup:
                content = Rect{};
                break;
        }
        boxes[item->id] = content;
        item->frame = Rect{content.x - item->paddingLeft, 0,
                           item->paddingLeft + len + item->paddingRight, height};
    }
    return boxes;
}

Rect bracketFrame(const Item& bracket, const std::vector<Item*>& members,
                  const std::unordered_map<int, Rect>& contentBoxes, double barHeight) {
    Rect box;
    for (const auto* member : members) {
        const auto it = contentBoxes.find(member->id);
        if (it == contentBoxes.end() || it->second.isZero() || it->second.width <= 0) continue;
        box = box.unionWith(it->second);
    }
    if (box.isEmpty()) return Rect{};
    return Rect{box.x - bracket.paddingLeft, 0,
                box.width + bracket.paddingLeft + bracket.paddingRight, barHeight};
}

} // namespace ybar::model
