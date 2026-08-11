// Monitor enumeration (spec section 6): the public contract is the 1-based
// arrangement index with the primary monitor first; internal identity uses
// the HMONITOR + device name for re-matching across WM_DISPLAYCHANGE.

#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "model/geometry.h"
#include "model/serialize.h"

namespace ybar::win {

struct MonitorInfo {
    std::uintptr_t handle = 0; // HMONITOR
    ybar::model::Rect frame;   // virtual-screen coords, y-down (native)
    ybar::model::Rect workArea;
    double scale = 1.0; // effective DPI / 96
    bool primary = false;
    int arrangementIndex = 1; // 1 = primary, then enumeration order
    std::wstring device;      // \\.\DISPLAYn (diagnostic)
};

// Primary first, then enumeration order.
std::vector<MonitorInfo> enumerateMonitors();

// --query displays payload.
std::vector<ybar::model::DisplayInfo> displayInfos();

} // namespace ybar::win
