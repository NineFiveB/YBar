// Popup member layouts (spec 3.9): vertical stack (default), horizontal row
// (cells normalized to the tallest), and wrap-flow (popup.wrap_width > 0 —
// lines wrap, members vertically centered per line). Pure math, injected
// measurement, panel inset 6.

#pragma once

#include <vector>

#include "model/geometry.h"
#include "model/item.h"
#include "model/layout.h"

namespace ybar::model {

struct PopupLayoutResult {
    Size panelSize;                 // popup content size incl. insets
    std::vector<Rect> contentBoxes; // per member, panel-local top-left origin
};

inline constexpr double kPopupInset = 6;

// members = in-order popup children of one host (position == Popup).
// cellHeight = popup.height (0 = per-row natural); natural row height =
// max(contentHeight + 8, 22), bare separator rows collapse to >= 10.
PopupLayoutResult layoutPopup(const std::vector<Item*>& members, const PopupState& popup,
                              const Measure& measure);

} // namespace ybar::model
