#include "model/bar_settings.h"

#include <algorithm>
#include <charconv>

#include "model/property_setter.h"

namespace ybar::model {

bool BarSettings::includesDisplay(int arrangementIndex, bool isMain) const {
    switch (displayPolicy) {
        case DisplayPolicy::All: return true;
        case DisplayPolicy::Main: return isMain;
        case DisplayPolicy::List:
            return std::find(displayList.begin(), displayList.end(), arrangementIndex) !=
                   displayList.end();
    }
    return true;
}

namespace {

using Result = std::optional<std::string>;

std::string lower(std::string_view text) {
    std::string out(text);
    for (auto& c : out)
        if (c >= 'A' && c <= 'Z') c += 32;
    return out;
}

std::optional<double> parseFloat(const std::string& value) {
    double parsed = 0;
    const char* begin = value.data();
    const char* end = begin + value.size();
    const auto [ptr, ec] = std::from_chars(begin, end, parsed);
    if (ec != std::errc() || ptr != end || value.empty()) return std::nullopt;
    return parsed;
}

Result setFloat(double& field, const std::string& value) {
    const auto parsed = parseFloat(value);
    if (!parsed) return "[!] invalid number: " + value;
    field = *parsed;
    return std::nullopt;
}

Result setBool(bool& field, const std::string& value, bool allowToggle) {
    if (allowToggle && lower(value) == "toggle") {
        field = !field;
        return std::nullopt;
    }
    const auto parsed = PropertySetter::parseBool(value);
    if (!parsed) return "[!] invalid boolean: " + value;
    field = *parsed;
    return std::nullopt;
}

Result setColor(Color& field, std::string_view channel, const std::string& value) {
    if (channel.empty() || channel == "hex") {
        const auto parsed = Color::parse(value);
        if (!parsed) return "[!] invalid color: " + value;
        field = *parsed;
        return std::nullopt;
    }
    int shift = -1;
    if (channel == "alpha") shift = 24;
    else if (channel == "red") shift = 16;
    else if (channel == "green") shift = 8;
    else if (channel == "blue") shift = 0;
    if (shift < 0) return "[?] unknown color channel: " + std::string(channel);
    const auto parsed = parseFloat(value);
    if (!parsed) return "[!] invalid number: " + value;
    const double clamped = std::clamp(*parsed, 0.0, 1.0);
    const auto byte = static_cast<std::uint32_t>(clamped * 255.0 + 0.5);
    field.argb = (field.argb & ~(0xffu << shift)) | (byte << shift);
    return std::nullopt;
}

} // namespace

std::optional<std::string> BarPropertySetter::set(BarSettings& s, std::string_view path,
                                                  const std::string& value) {
    if (path.empty()) return "[!] empty property";
    const auto dot = path.find('.');
    const auto key = path.substr(0, dot);
    const auto channel = dot == std::string_view::npos ? std::string_view{} : path.substr(dot + 1);

    if (key == "position") {
        const auto v = lower(value);
        if (v == "top") s.position = BarPosition::Top;
        else if (v == "bottom") s.position = BarPosition::Bottom;
        else return "[!] invalid position: " + value;
        return std::nullopt;
    }
    if (key == "height") return setFloat(s.height, value);
    if (key == "margin") return setFloat(s.margin, value);
    if (key == "y_offset") return setFloat(s.yOffset, value);
    if (key == "padding_left") return setFloat(s.paddingLeft, value);
    if (key == "padding_right") return setFloat(s.paddingRight, value);
    if (key == "color") return setColor(s.color, channel, value);
    if (key == "border_color") return setColor(s.borderColor, channel, value);
    if (key == "border_width") return setFloat(s.borderWidth, value);
    if (key == "corner_radius") return setFloat(s.cornerRadius, value);
    if (key == "gradient_color") {
        Color color = s.gradientColor.value_or(Color{});
        const auto result = setColor(color, channel, value);
        if (!result) s.gradientColor = color;
        return result;
    }
    if (key == "gradient_angle") return setFloat(s.gradientAngle, value);
    if (key == "blur_radius") return setFloat(s.blurRadius, value);
    if (key == "idle_inhibit") return setBool(s.idleInhibit, value, /*allowToggle=*/true);
    if (key == "shadow") return setBool(s.shadow, value, false);
    if (key == "hidden") return setBool(s.hidden, value, /*allowToggle=*/true);
    if (key == "topmost") {
        const auto v = lower(value);
        if (v == "off") s.topmost = BarLevel::Off;
        else if (v == "window") s.topmost = BarLevel::Window;
        else if (v == "on") s.topmost = BarLevel::On;
        else return "[!] invalid topmost: " + value;
        return std::nullopt;
    }
    if (key == "sticky") return setBool(s.sticky, value, false);
    if (key == "notch_width") return setFloat(s.notchWidth, value);
    if (key == "notch_offset") return setFloat(s.notchOffset, value);
    if (key == "notch_display_height") return setFloat(s.notchDisplayHeight, value);
    if (key == "display") {
        const auto v = lower(value);
        if (v == "all") { s.displayPolicy = DisplayPolicy::All; s.displayList.clear(); return std::nullopt; }
        if (v == "main") { s.displayPolicy = DisplayPolicy::Main; s.displayList.clear(); return std::nullopt; }
        std::vector<int> list;
        std::size_t start = 0;
        for (std::size_t i = 0; i <= value.size(); ++i) {
            if (i == value.size() || value[i] == ',') {
                const std::string part = value.substr(start, i - start);
                start = i + 1;
                if (part.empty()) continue; // empty components are dropped
                int parsed = 0;
                const auto [ptr, ec] = std::from_chars(part.data(), part.data() + part.size(), parsed);
                if (ec != std::errc() || ptr != part.data() + part.size() || parsed < 1)
                    return "[!] invalid display list: " + value;
                list.push_back(parsed);
            }
        }
        s.displayPolicy = DisplayPolicy::List;
        s.displayList = std::move(list);
        return std::nullopt;
    }
    if (key == "glass") return setBool(s.glass, value, false);
    if (key == "fullscreen_show" || key == "show_in_fullscreen")
        return setBool(s.fullscreenShow, value, false);
    if (key == "wifi_ssid_prompt") return std::nullopt; // accepted; hook wired later
    if (key == "font_smoothing") return std::nullopt;   // accepted no-op (compat)
    if (key == "reserve") {                             // Windows extension (spec 6.1)
        const auto v = lower(value);
        if (v == "komorebi") s.reserve = ReserveMode::Komorebi;
        else if (v == "appbar") s.reserve = ReserveMode::AppBar;
        else if (v == "off") s.reserve = ReserveMode::Off;
        else if (v == "auto") s.reserve = ReserveMode::Auto;
        else return "[!] invalid reserve: " + value;
        return std::nullopt;
    }
    return "[?] unknown bar property: " + std::string(path);
}

} // namespace ybar::model
