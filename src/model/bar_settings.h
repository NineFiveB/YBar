// Bar-level settings and the --bar property grammar (spec sections 3.3, 6).
// Defaults and error strings are parity contracts.

#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "model/color.h"

namespace ybar::model {

enum class BarPosition { Top, Bottom };
enum class BarLevel { Off, Window, On };            // topmost triad
enum class DisplayPolicy { All, Main, List };
enum class ReserveMode { Auto, Komorebi, AppBar, Off }; // Windows extension

struct BarSettings {
    BarPosition position = BarPosition::Top;
    double height = 25;
    double margin = 0;
    double yOffset = 0;
    double paddingLeft = 0;
    double paddingRight = 0;
    Color color{0x44000000};
    std::optional<Color> gradientColor;
    double gradientAngle = 0;
    Color borderColor{0x00000000};
    double borderWidth = 0;
    double cornerRadius = 0;
    double cornerExponent = 2;
    double blurRadius = 0;
    bool glass = false;
    bool fullscreenShow = false;
    bool hidden = false;
    BarLevel topmost = BarLevel::Off;
    bool sticky = true;
    bool shadow = false;
    bool idleInhibit = false;
    bool wifiSsidPrompt = false;
    DisplayPolicy displayPolicy = DisplayPolicy::All;
    std::vector<int> displayList; // 1-based arrangement indices when List
    double notchWidth = 200;      // accepted; no layout effect on Windows
    double notchOffset = 0;
    double notchDisplayHeight = 0;
    ReserveMode reserve = ReserveMode::Auto;

    bool includesDisplay(int arrangementIndex, bool isMain) const;
};

class BarPropertySetter {
public:
    // nullopt = success; error strings are verbatim contract.
    static std::optional<std::string> set(BarSettings& settings, std::string_view key,
                                          const std::string& value);
};

} // namespace ybar::model
