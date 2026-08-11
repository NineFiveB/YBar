// Five-cursor bar layout as a pure function (spec sections 3.9, 8).
// Measurement is injected — the DirectWrite text measurer lives elsewhere.

#pragma once

#include <functional>
#include <unordered_map>

#include "model/geometry.h"
#include "model/item.h"

namespace ybar::model {

struct MeasuredContent {
    Size icon;
    Size label;
};

using Measure = std::function<MeasuredContent(const Item&)>;

struct LayoutSettings {
    double width = 0;       // bar content width
    double height = 0;      // bar height
    double paddingLeft = 0; // bar padding
    double paddingRight = 0;
    double notchWidth = 0;  // q/e dead zone; 0 on Windows unless configured
};

// Advance of one text part: 0 when not drawing; customWidth REPLACES
// ink+paddings when >= 0; else paddingLeft + measured width + paddingRight.
double partAdvance(const TextPart& part, const Size& measured);

// Item content length honoring the fixed-width override; a gauge's label
// renders inside the dial and contributes zero width.
double contentLength(const Item& item, const MeasuredContent& measured);

// Natural length ignoring item-level fixed width (width=dynamic animations).
double naturalLength(const Item& item, const MeasuredContent& measured);

// Lays out in-flow items, writes item.frame (full interactive extent), and
// returns per-item-id content boxes (bar-local, top-left origin). Brackets,
// popup members, and invisible items get zero frames.
std::unordered_map<int, Rect> layout(const std::vector<std::unique_ptr<Item>>& items,
                                     const LayoutSettings& settings, const Measure& measure);

// Bracket background/interactive frame = union of member content boxes
// expanded by bracket paddings, full bar height; zero when no visible member.
Rect bracketFrame(const Item& bracket, const std::vector<Item*>& members,
                  const std::unordered_map<int, Rect>& contentBoxes, double barHeight);

} // namespace ybar::model
