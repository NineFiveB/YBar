#include "model/style.h"

namespace ybar::model {

std::string TextPart::displayString() const {
    if (maxChars <= 0) return string;
    // Count UTF-8 code points; truncate to maxChars and append an ellipsis.
    int count = 0;
    std::size_t cutoff = string.size();
    bool truncated = false;
    for (std::size_t i = 0; i < string.size();) {
        const auto byte = static_cast<unsigned char>(string[i]);
        std::size_t len = 1;
        if ((byte & 0xf8) == 0xf0) len = 4;
        else if ((byte & 0xf0) == 0xe0) len = 3;
        else if ((byte & 0xe0) == 0xc0) len = 2;
        if (count == maxChars) {
            cutoff = i;
            truncated = true;
            break;
        }
        i += len;
        ++count;
    }
    if (!truncated) return string;
    return string.substr(0, cutoff) + "\xe2\x80\xa6"; // U+2026
}

std::optional<ItemPosition> parsePosition(std::string_view token) {
    if (token == "left" || token == "l") return ItemPosition::Left;
    if (token == "right" || token == "r") return ItemPosition::Right;
    if (token == "center" || token == "c") return ItemPosition::Center;
    if (token == "q" || token == "center_left") return ItemPosition::CenterLeft;
    if (token == "e" || token == "center_right") return ItemPosition::CenterRight;
    return std::nullopt;
}

std::string_view positionRawValue(ItemPosition position) {
    switch (position) {
        case ItemPosition::Left: return "left";
        case ItemPosition::Right: return "right";
        case ItemPosition::Center: return "center";
        case ItemPosition::CenterLeft: return "q";
        case ItemPosition::CenterRight: return "e";
        case ItemPosition::Popup: return "p";
    }
    return "left";
}

} // namespace ybar::model
