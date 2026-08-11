// --query JSON serialization (spec section 3.6). Key names and shapes are
// verbatim contract ("arrangement-id", "DirectDisplayID", "on"/"off" strings,
// lowercase "0x%08x" colors); pretty-printed with sorted keys.

#pragma once

#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

#include "events/event_bus.h"
#include "model/bar_settings.h"
#include "model/geometry.h"
#include "model/item.h"

namespace ybar::model {

struct DisplayInfo {
    int arrangementId = 1; // 1-based; 1 = primary
    Rect frame;            // global y-down device-independent points
    double scale = 1.0;
    bool main = false;
    std::uint32_t directDisplayId = 0; // platform-defined stable id
};

// bounding_rects: {"display-<N>": rect} of bar-local frames per display.
using BoundingRects = std::unordered_map<int, Rect>;

std::string serializeBar(const BarSettings& settings, const ItemStore& store);
std::string serializeItem(const Item& item, const BoundingRects& boundingRects);
std::string serializeDefaults(const Item& defaults);
std::string serializeEvents(const events::EventBus& bus);
std::string serializeDisplays(const std::vector<DisplayInfo>& displays);

} // namespace ybar::model
