#include "model/serialize.h"

#include <nlohmann/json.hpp>

namespace ybar::model {

using nlohmann::json;

namespace {

std::string onOff(bool value) { return value ? "on" : "off"; }

json shadowDict(const ShadowStyle& shadow) {
    return {
        {"drawing", onOff(shadow.drawing)},
        {"color", shadow.color.hex()},
        {"distance", shadow.distance},
        {"angle", shadow.angle},
    };
}

json backgroundDict(const BackgroundStyle& bg) {
    return {
        {"drawing", onOff(bg.drawing)},
        {"color", bg.color.hex()},
        {"border_color", bg.borderColor.hex()},
        {"border_width", bg.borderWidth},
        {"corner_radius", bg.cornerRadius},
        {"height", bg.height},
        {"padding_left", bg.paddingLeft},
        {"padding_right", bg.paddingRight},
        {"x_offset", bg.xOffset},
        {"y_offset", bg.yOffset},
        {"shadow", shadowDict(bg.shadow)},
    };
}

json textDict(const TextPart& text) {
    return {
        {"value", text.string},
        {"drawing", onOff(text.drawing)},
        {"color", text.color.hex()},
        {"highlight", text.highlight},
        {"highlight_color", text.highlightColor.hex()},
        {"font", text.font.serialize()},
        {"padding_left", text.paddingLeft},
        {"padding_right", text.paddingRight},
        {"y_offset", text.yOffset},
        {"max_chars", text.maxChars},
        {"background", backgroundDict(text.background)},
    };
}

std::string updatesString(UpdatePolicy policy) {
    switch (policy) {
        case UpdatePolicy::On: return "on";
        case UpdatePolicy::Off: return "off";
        case UpdatePolicy::WhenShown: return "when_shown";
    }
    return "on";
}

std::string typeString(const Item& item) {
    switch (item.kind) {
        case ItemKind::Item: return "item";
        case ItemKind::Bracket: return "bracket";
        case ItemKind::Graph: return "graph";
        case ItemKind::Slider: return "slider";
        case ItemKind::Alias: return "alias";
    }
    return "item";
}

json itemDict(const Item& item, const BoundingRects& boundingRects) {
    json geometry = {
        {"drawing", onOff(item.drawing)},
        {"position", std::string(positionRawValue(item.position))},
        {"associated_display_mask", item.associatedDisplayMask},
        {"y_offset", item.yOffset},
        {"padding_left", item.paddingLeft},
        {"padding_right", item.paddingRight},
        {"width", item.customWidth},
        {"align", std::string(1, item.align)},
        {"background", backgroundDict(item.background)},
    };
    json rects = json::object();
    for (const auto& [display, rect] : boundingRects) {
        if (rect.isZero()) continue;
        rects["display-" + std::to_string(display)] = {
            {"origin", {rect.x, rect.y}},
            {"size", {rect.width, rect.height}},
        };
    }
    json result = {
        {"name", item.name},
        {"type", typeString(item)},
        {"geometry", geometry},
        {"icon", textDict(item.icon)},
        {"label", textDict(item.label)},
        {"scripting",
         {
             {"script", item.script},
             {"click_script", item.clickScript},
             {"update_freq", item.updateFrequency},
             {"update_mask", item.updateMask},
             {"updates", updatesString(item.updatePolicy)},
         }},
        {"bounding_rects", rects},
    };
    if (item.kind == ItemKind::Bracket) result["bracket"] = item.members;
    if (item.graph) {
        result["graph"] = {
            {"width", item.graph->capacity},
            {"color", item.graph->lineColor.hex()},
            {"fill_color", item.graph->effectiveFillColor().hex()},
            {"line_width", item.graph->lineWidth},
        };
    }
    if (item.slider) {
        result["slider"] = {
            {"percentage", item.slider->percentage},
            {"width", item.slider->width},
            {"highlight_color", item.slider->highlightColor.hex()},
            {"interactive", item.slider->interactive ? "on" : "off"},
        };
    }
    if (item.image) {
        result["image"] = {
            {"string", item.image->source},
            {"size", item.image->size},
            {"drawing", onOff(item.image->drawing)},
        };
    }
    if (item.gauge) {
        result["gauge"] = {
            {"percentage", item.gauge->percentage},
            {"size", item.gauge->size},
            {"thickness", item.gauge->thickness},
            {"color", item.gauge->color.hex()},
            {"track_color", item.gauge->trackColor.hex()},
        };
    }
    result["popup"] = {
        {"drawing", onOff(item.popup.isOpen)},
        {"horizontal", item.popup.horizontal},
        {"wrap_width", item.popup.wrapWidth},
        {"height", item.popup.cellHeight},
        {"auto_close", item.popup.autoClose},
    };
    if (item.position == ItemPosition::Popup) result["popup_host"] = item.popupHost;
    return result;
}

std::string dump(const json& value) { return value.dump(2); }

} // namespace

std::string serializeBar(const BarSettings& s, const ItemStore& store) {
    json items = json::array();
    for (const auto& item : store.items()) items.push_back(item->name);
    return dump({
        {"position", s.position == BarPosition::Top ? "top" : "bottom"},
        {"height", s.height},
        {"margin", s.margin},
        {"y_offset", s.yOffset},
        {"padding_left", s.paddingLeft},
        {"padding_right", s.paddingRight},
        {"color", s.color.hex()},
        {"border_color", s.borderColor.hex()},
        {"border_width", s.borderWidth},
        {"corner_radius", s.cornerRadius},
        {"blur_radius", s.blurRadius},
        // hidden/sticky/idle_inhibit are JSON booleans in the reference
        // (unlike item-level "drawing", which is an on/off string).
        {"hidden", s.hidden},
        {"topmost", s.topmost == BarLevel::Off      ? "off"
                    : s.topmost == BarLevel::Window ? "window"
                                                    : "on"},
        {"sticky", s.sticky},
        {"idle_inhibit", s.idleInhibit},
        {"notch_width", s.notchWidth},
        {"notch_offset", s.notchOffset},
        {"notch_display_height", s.notchDisplayHeight},
        {"items", items},
    });
}

std::string serializeItem(const Item& item, const BoundingRects& boundingRects) {
    return dump(itemDict(item, boundingRects));
}

std::string serializeDefaults(const Item& defaults) {
    return dump(itemDict(defaults, {}));
}

std::string serializeEvents(const events::EventBus& bus) {
    json result = json::object();
    for (const auto& def : bus.definitions()) {
        result[def.name] = {
            {"bit", def.bit},
            {"notification", def.notification.empty() ? "(null)" : def.notification},
        };
    }
    return dump(result);
}

std::string serializeDisplays(const std::vector<DisplayInfo>& displays) {
    json result = json::array();
    for (const auto& display : displays) {
        result.push_back({
            {"arrangement-id", display.arrangementId},
            {"frame",
             {{"x", display.frame.x},
              {"y", display.frame.y},
              {"w", display.frame.width},
              {"h", display.frame.height}}},
            {"scale", display.scale},
            {"main", display.main},
            {"DirectDisplayID", display.directDisplayId},
        });
    }
    return dump(result);
}

} // namespace ybar::model
