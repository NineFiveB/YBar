#include "model/popup_layout.h"

#include <algorithm>

namespace ybar::model {

namespace {

struct Measured {
    Item* item;
    double length;        // content length (fixed width honored)
    double contentHeight; // max part height
    bool separator;       // no visible content -> slim separator row
};

Measured measureMember(Item* item, const Measure& measure) {
    // A member with drawing=off contributes nothing at all (matching bar
    // layout, where invisible items get zero frames) — not a separator row.
    if (!item->drawing) return Measured{item, 0, 0, true};
    const auto m = measure(*item);
    Measured result{item, contentLength(*item, m),
                    std::max(item->icon.drawing ? m.icon.height : 0.0,
                             item->label.drawing ? m.label.height : 0.0),
                    false};
    result.separator = !item->isVisibleInFlow() ||
                       (result.length <= 0 && result.contentHeight <= 0);
    return result;
}

double rowHeight(const Measured& member, double cellHeight) {
    if (cellHeight > 0) return cellHeight;
    if (member.separator) return std::max(member.contentHeight + 8, 10.0);
    return std::max(member.contentHeight + 8, 22.0);
}

} // namespace

PopupLayoutResult layoutPopup(const std::vector<Item*>& members, const PopupState& popup,
                              const Measure& measure) {
    PopupLayoutResult result;
    if (members.empty()) return result;

    std::vector<Measured> measured;
    measured.reserve(members.size());
    for (auto* member : members) measured.push_back(measureMember(member, measure));

    if (popup.wrapWidth > 0) {
        // Wrap-flow: left-to-right lines, wrap when the advance would exceed
        // inset + wrapWidth; a line's first member never wraps.
        double y = kPopupInset;
        double lineHeight = 0;
        double x = kPopupInset;
        std::size_t lineStart = 0;
        std::vector<double> xs(measured.size());
        std::vector<std::size_t> lines(measured.size());
        std::vector<double> lineTops;
        std::vector<double> lineHeights;

        auto flushLine = [&](std::size_t end) {
            lineTops.push_back(y);
            lineHeights.push_back(lineHeight);
            y += lineHeight;
            x = kPopupInset;
            lineHeight = 0;
            lineStart = end;
        };
        for (std::size_t i = 0; i < measured.size(); ++i) {
            const auto& member = measured[i];
            const double advance =
                member.item->paddingLeft + member.length + member.item->paddingRight;
            if (i > lineStart && x + advance > kPopupInset + popup.wrapWidth) flushLine(i);
            xs[i] = x + member.item->paddingLeft;
            lines[i] = lineTops.size(); // current (unflushed) line index
            x += advance;
            lineHeight = std::max(lineHeight, rowHeight(member, popup.cellHeight));
        }
        flushLine(measured.size());

        result.contentBoxes.resize(measured.size());
        for (std::size_t i = 0; i < measured.size(); ++i) {
            const auto line = lines[i];
            const double height = rowHeight(measured[i], popup.cellHeight);
            result.contentBoxes[i] =
                Rect{xs[i], lineTops[line] + (lineHeights[line] - height) / 2,
                     measured[i].length, height};
        }
        result.panelSize = {popup.wrapWidth + 2 * kPopupInset, y + kPopupInset};
        return result;
    }

    if (popup.horizontal) {
        // Single row, cells normalized to the tallest.
        double maxHeight = 0;
        for (const auto& member : measured)
            maxHeight = std::max(maxHeight, rowHeight(member, popup.cellHeight));
        double x = kPopupInset;
        for (const auto& member : measured) {
            x += member.item->paddingLeft;
            result.contentBoxes.push_back(Rect{x, kPopupInset, member.length, maxHeight});
            x += member.length + member.item->paddingRight;
        }
        result.panelSize = {x + kPopupInset, maxHeight + 2 * kPopupInset};
        return result;
    }

    // Vertical stack (default): row width = padL + length + padR; panel is
    // the widest row plus insets.
    double y = kPopupInset;
    double widest = 0;
    for (const auto& member : measured) {
        const double height = rowHeight(member, popup.cellHeight);
        result.contentBoxes.push_back(
            Rect{kPopupInset + member.item->paddingLeft, y, member.length, height});
        y += height;
        widest = std::max(widest,
                          member.item->paddingLeft + member.length + member.item->paddingRight);
    }
    result.panelSize = {widest + 2 * kPopupInset, y + kPopupInset};
    return result;
}

} // namespace ybar::model
