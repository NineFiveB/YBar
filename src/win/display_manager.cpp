#include "win/display_manager.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellscalingapi.h>
// clang-format on

#include <algorithm>
#include <functional>

namespace ybar::win {

namespace {

ybar::model::Rect toRect(const RECT& r) {
    return {static_cast<double>(r.left), static_cast<double>(r.top),
            static_cast<double>(r.right - r.left), static_cast<double>(r.bottom - r.top)};
}

} // namespace

std::vector<MonitorInfo> enumerateMonitors() {
    std::vector<MonitorInfo> monitors;
    const auto callback = [](HMONITOR monitor, HDC, LPRECT, LPARAM param) -> BOOL {
        auto* list = reinterpret_cast<std::vector<MonitorInfo>*>(param);
        MONITORINFOEXW info{};
        info.cbSize = sizeof(info);
        if (!GetMonitorInfoW(monitor, &info)) return TRUE;
        MonitorInfo entry;
        entry.handle = reinterpret_cast<std::uintptr_t>(monitor);
        entry.frame = toRect(info.rcMonitor);
        entry.workArea = toRect(info.rcWork);
        entry.primary = (info.dwFlags & MONITORINFOF_PRIMARY) != 0;
        entry.device = info.szDevice;
        UINT dpiX = 96;
        UINT dpiY = 96;
        if (SUCCEEDED(GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)))
            entry.scale = static_cast<double>(dpiX) / 96.0;
        list->push_back(entry);
        return TRUE;
    };
    EnumDisplayMonitors(nullptr, nullptr, callback,
                        reinterpret_cast<LPARAM>(&monitors));

    // Primary first (arrangement index 1), then enumeration order.
    std::stable_sort(monitors.begin(), monitors.end(),
                     [](const MonitorInfo& a, const MonitorInfo& b) {
                         return a.primary && !b.primary;
                     });
    for (std::size_t i = 0; i < monitors.size(); ++i)
        monitors[i].arrangementIndex = static_cast<int>(i) + 1;
    return monitors;
}

std::vector<ybar::model::DisplayInfo> displayInfos() {
    std::vector<ybar::model::DisplayInfo> result;
    for (const auto& monitor : enumerateMonitors()) {
        ybar::model::DisplayInfo info;
        info.arrangementId = monitor.arrangementIndex;
        info.frame = monitor.frame;
        info.scale = monitor.scale;
        info.main = monitor.primary;
        // Platform-defined stable-ish id: FNV-1a of the device name.
        std::uint32_t hash = 2166136261u;
        for (const wchar_t c : monitor.device) {
            hash ^= static_cast<std::uint32_t>(c);
            hash *= 16777619u;
        }
        info.directDisplayId = hash;
        result.push_back(info);
    }
    return result;
}

} // namespace ybar::win
