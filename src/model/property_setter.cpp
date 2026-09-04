#include "model/property_setter.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <functional>
#include <vector>

namespace ybar::model {

namespace {

using Segments = std::vector<std::string_view>;

Segments split(std::string_view path) {
    Segments segments;
    std::size_t start = 0;
    for (std::size_t i = 0; i <= path.size(); ++i) {
        if (i == path.size() || path[i] == '.') {
            segments.push_back(path.substr(start, i - start));
            start = i + 1;
        }
    }
    return segments;
}

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
    // from_chars accepts inf/nan; the reference requires a finite number
    // (an infinite padding would poison layout).
    if (!std::isfinite(parsed)) return std::nullopt;
    return parsed;
}

std::optional<int> parseInt(const std::string& value) {
    int parsed = 0;
    const char* begin = value.data();
    const char* end = begin + value.size();
    const auto [ptr, ec] = std::from_chars(begin, end, parsed);
    if (ec != std::errc() || ptr != end || value.empty()) return std::nullopt;
    return parsed;
}

// --- error strings (verbatim contract) ---
std::string errNumber(const std::string& v) { return "[!] invalid number: " + v; }
std::string errColor(const std::string& v) { return "[!] invalid color: " + v; }
std::string errBool(const std::string& v) { return "[!] invalid boolean: " + v; }
std::string errUnknown(std::string_view path) {
    return "[?] unknown property: " + std::string(path);
}
std::string errChannel(std::string_view channel) {
    return "[?] unknown color channel: " + std::string(channel);
}

using Result = std::optional<std::string>;
constexpr std::nullopt_t ok = std::nullopt;

// Message-scoped animation state (UI-thread only, spec 3.8).
const ybar::model::PropertySetter::AnimationContext* g_animation = nullptr;
std::string g_currentPath; // full dotted path of the set in progress

std::string animationKey() {
    return "item." + std::to_string(g_animation ? g_animation->itemId : 0) + "." +
           g_currentPath;
}

Result setFloat(double& field, const std::string& value) {
    const auto parsed = parseFloat(value);
    if (!parsed) return errNumber(value);
    if (g_animation && g_animation->scheduler) {
        if (g_animation->frames > 0) {
            g_animation->scheduler->add(
                animationKey(), g_animation->curve, g_animation->frames, field, *parsed,
                [&field](const ybar::anim::AnimValue& v) { field = std::get<double>(v); });
            return ok;
        }
        g_animation->scheduler->cancel(animationKey()); // direct set cancels
    }
    field = *parsed;
    return ok;
}

// Animatable float leaf whose value is bounded. setFloat cannot be reused for
// these: it writes the raw lerp, and a meter clamped only at the set site
// would still be driven out of range by an animation aimed past an endpoint.
// Clamping inside the apply callback keeps every intermediate frame legal.
Result setFloatClamped(double& field, const std::string& value, double lo, double hi) {
    const auto parsed = parseFloat(value);
    if (!parsed) return errNumber(value);
    const double target = std::clamp(*parsed, lo, hi);
    if (g_animation && g_animation->scheduler) {
        if (g_animation->frames > 0) {
            g_animation->scheduler->add(
                animationKey(), g_animation->curve, g_animation->frames, field, target,
                [&field, lo, hi](const ybar::anim::AnimValue& v) {
                    field = std::clamp(std::get<double>(v), lo, hi);
                });
            return ok;
        }
        g_animation->scheduler->cancel(animationKey()); // direct set cancels
    }
    field = target;
    return ok;
}

// Non-animatable float leaf (reference treats clip/wrap_width as direct sets).
// NEVER route a stack local through setFloat: the scheduler keeps the capture
// alive and would write through a dangling reference every tick.
Result setFloatDirect(double& field, const std::string& value, double minimum) {
    const auto parsed = parseFloat(value);
    if (!parsed) return errNumber(value);
    if (g_animation && g_animation->scheduler) g_animation->scheduler->cancel(animationKey());
    field = std::max(minimum, *parsed);
    return ok;
}

// Animatable color leaf addressed through a setter closure — for fields that
// live behind std::optional (gradient_color, graph.fill_color) and so have no
// stable Color& to capture.
Result setColorVia(Color current, const std::function<void(Color)>& apply,
                   const std::string& value) {
    const auto parsed = Color::parse(value);
    if (!parsed) return errColor(value);
    if (g_animation && g_animation->scheduler) {
        if (g_animation->frames > 0) {
            g_animation->scheduler->add(
                animationKey(), g_animation->curve, g_animation->frames, current, *parsed,
                [apply](const ybar::anim::AnimValue& v) { apply(std::get<Color>(v)); });
            return ok;
        }
        g_animation->scheduler->cancel(animationKey());
    }
    apply(*parsed);
    return ok;
}

// `width=<n>` is a plain animatable float; `width=dynamic` stores the -1
// sentinel. Under --animate the sentinel is resolved to the measured natural
// width at BOTH endpoints so the value never lerps toward -1 — sketchybar's
// flagship width-animation idiom (spec 3.3). `measureNatural` is null in
// headless contexts, where `dynamic` degrades to a direct set.
Result setWidthWithDynamic(double& field, const std::string& value,
                           const std::function<double()>& measureNatural) {
    const bool animating =
        g_animation && g_animation->scheduler && g_animation->frames > 0 && measureNatural;
    if (lower(value) == "dynamic") {
        if (animating && field >= 0) {
            const std::string key = animationKey();
            g_animation->scheduler->add(
                key, g_animation->curve, g_animation->frames, field, measureNatural(),
                [&field](const ybar::anim::AnimValue& v) { field = std::get<double>(v); },
                // Only on natural completion: hand the sentinel back so the
                // item resumes tracking its content.
                [&field] { field = -1; });
            return ok;
        }
        if (g_animation && g_animation->scheduler) g_animation->scheduler->cancel(animationKey());
        field = -1;
        return ok;
    }
    // Animating away from `dynamic` needs a real starting point too.
    if (animating && field < 0) field = measureNatural();
    return setFloat(field, value);
}

Result setBool(bool& field, const std::string& value) {
    if (lower(value) == "toggle") {
        field = !field;
        return ok;
    }
    const auto parsed = PropertySetter::parseBool(value);
    if (!parsed) return errBool(value);
    field = *parsed;
    return ok;
}

// Color leaf with .alpha/.red/.green/.blue/.hex channel addressing.
Result setColor(Color& field, const Segments& segs, std::size_t at, const std::string& value,
                std::string_view fullPath) {
    if (at >= segs.size()) {
        const auto parsed = Color::parse(value);
        if (!parsed) return errColor(value);
        if (g_animation && g_animation->scheduler) {
            if (g_animation->frames > 0) { // linear-light color animation
                g_animation->scheduler->add(
                    animationKey(), g_animation->curve, g_animation->frames, field, *parsed,
                    [&field](const ybar::anim::AnimValue& v) {
                        field = std::get<Color>(v);
                    });
                return ok;
            }
            g_animation->scheduler->cancel(animationKey());
        }
        field = *parsed;
        return ok;
    }
    if (at + 1 != segs.size()) return errUnknown(fullPath);
    const auto channel = segs[at];
    if (channel == "hex") {
        const auto parsed = Color::parse(value);
        if (!parsed) return errColor(value);
        field = *parsed;
        return ok;
    }
    int shift = -1;
    if (channel == "alpha") shift = 24;
    else if (channel == "red") shift = 16;
    else if (channel == "green") shift = 8;
    else if (channel == "blue") shift = 0;
    if (shift < 0) return errChannel(channel);
    const auto parsed = parseFloat(value);
    if (!parsed) return errNumber(value);
    const double clamped = std::clamp(*parsed, 0.0, 1.0);
    const auto byte = static_cast<std::uint32_t>(clamped * 255.0 + 0.5);
    field.argb = (field.argb & ~(0xffu << shift)) | (byte << shift);
    return ok;
}

// Align accepts only l/c/r (reference validates; an invalid align must not
// silently reach layout).
std::optional<char> parseAlignChar(const std::string& value) {
    if (value.empty()) return std::nullopt;
    const char first = value.front();
    if (first == 'l' || first == 'c' || first == 'r') return first;
    return std::nullopt;
}

Result setShadow(ShadowStyle& shadow, const Segments& segs, std::size_t at,
                 const std::string& value, std::string_view fullPath) {
    if (at >= segs.size()) return setBool(shadow.drawing, value); // bare = drawing
    const auto key = segs[at];
    if (key == "drawing") return setBool(shadow.drawing, value);
    if (key == "color") return setColor(shadow.color, segs, at + 1, value, fullPath);
    if (key == "distance") return setFloat(shadow.distance, value);
    if (key == "angle") return setFloat(shadow.angle, value);
    if (key == "blur") return setFloat(shadow.blur, value);
    return errUnknown(fullPath);
}

Result setBackground(BackgroundStyle& bg, const Segments& segs, std::size_t at,
                     const std::string& value, std::string_view fullPath) {
    // Bare "background=" is an error, not an unknown property (reference).
    if (at >= segs.size()) return "[!] background needs a sub-property";
    const auto key = segs[at];
    if (key == "drawing") return setBool(bg.drawing, value);
    if (key == "color") {
        // Reference enables drawing BEFORE parsing: even an invalid color
        // leaves the background drawing.
        bg.drawing = true;
        return setColor(bg.color, segs, at + 1, value, fullPath);
    }
    if (key == "border_color") return setColor(bg.borderColor, segs, at + 1, value, fullPath);
    if (key == "border_width") return setFloat(bg.borderWidth, value);
    if (key == "corner_radius") return setFloat(bg.cornerRadius, value);
    if (key == "height") return setFloat(bg.height, value);
    if (key == "padding_left") return setFloat(bg.paddingLeft, value);
    if (key == "padding_right") return setFloat(bg.paddingRight, value);
    if (key == "x_offset") return setFloat(bg.xOffset, value);
    if (key == "y_offset") return setFloat(bg.yOffset, value);
    if (key == "glass") return setBool(bg.glass, value);
    if (key == "gradient_color") {
        // Whole-color only (reference rejects channel addressing here).
        if (at + 1 != segs.size()) return errColor(value);
        const auto result = setColorVia(bg.gradientColor.value_or(Color{}),
                                        [&bg](Color c) { bg.gradientColor = c; }, value);
        if (!result) bg.drawing = true; // gradient_color auto-enables drawing
        return result;
    }
    if (key == "gradient_angle") return setFloat(bg.gradientAngle, value);
    if (key == "clip") {
        const auto result = setFloatDirect(bg.clip, value, 0.0);
        if (result) return "[!] invalid clip: " + value;
        return ok;
    }
    if (key == "image") {
        if (at + 1 >= segs.size()) { // bare: source string, force-enables drawing
            bg.imageSource = value;
            bg.drawing = true;
            return ok;
        }
        const auto sub = segs[at + 1];
        if (sub == "string") {
            bg.imageSource = value;
            bg.drawing = true;
            return ok;
        }
        if (sub == "scale") {
            const auto parsed = parseFloat(value);
            if (!parsed || *parsed <= 0) return "[!] invalid image.scale: " + value;
            bg.imageScale = *parsed;
            return ok;
        }
        // Reference wording: a plain `[!] invalid boolean:` here; the
        // `[!] invalid image.drawing:` form belongs to the item-level image.
        if (sub == "drawing") return setBool(bg.imageDrawing, value);
        return ok; // background.image.<anything else> accepted-and-ignored
    }
    if (key == "shadow") return setShadow(bg.shadow, segs, at + 1, value, fullPath);
    return errUnknown(fullPath);
}

// `measureNaturalPart` resolves this part's `width=dynamic` sentinel; empty
// for parts with no measurer wired (slider knobs, headless contexts).
Result setText(TextPart& text, const Segments& segs, std::size_t at, const std::string& value,
               std::string_view fullPath,
               const std::function<double()>& measureNaturalPart = {}) {
    if (at >= segs.size()) { // bare = string
        text.string = value;
        return ok;
    }
    const auto key = segs[at];
    if (key == "string") { text.string = value; return ok; }
    if (key == "drawing") return setBool(text.drawing, value);
    if (key == "color") return setColor(text.color, segs, at + 1, value, fullPath);
    if (key == "highlight") return setBool(text.highlight, value);
    if (key == "highlight_color") return setColor(text.highlightColor, segs, at + 1, value, fullPath);
    if (key == "font") {
        if (at + 1 >= segs.size()) {
            if (!text.font.apply(value)) return errNumber(value);
            return ok;
        }
        const auto sub = segs[at + 1];
        if (sub == "family") { text.font.family = value; return ok; }
        if (sub == "style") { text.font.style = value; return ok; }
        if (sub == "size") {
            const auto parsed = parseFloat(value);
            if (!parsed || *parsed <= 0) return errNumber(value);
            text.font.size = *parsed;
            return ok;
        }
        if (sub == "features") return ok; // accepted-and-ignored
        return errUnknown(fullPath);
    }
    if (key == "padding_left") return setFloat(text.paddingLeft, value);
    if (key == "padding_right") return setFloat(text.paddingRight, value);
    if (key == "y_offset") return setFloat(text.yOffset, value);
    if (key == "scroll_duration") {
        const auto parsed = parseInt(value);
        if (!parsed || *parsed <= 0) return "[!] invalid scroll_duration: " + value;
        text.scrollDuration = *parsed;
        return ok;
    }
    if (key == "max_chars") {
        const auto parsed = parseInt(value);
        if (!parsed || *parsed < 0) return "[!] invalid max_chars: " + value;
        text.maxChars = *parsed;
        return ok;
    }
    if (key == "width")
        return setWidthWithDynamic(text.customWidth, value, measureNaturalPart);
    if (key == "align") {
        const auto align = parseAlignChar(value);
        if (!align) return "[!] invalid align: " + value;
        text.align = *align;
        return ok;
    }
    if (key == "background") return setBackground(text.background, segs, at + 1, value, fullPath);
    if (key == "shadow") return setShadow(text.shadow, segs, at + 1, value, fullPath);
    return errUnknown(fullPath);
}

Result setGraph(Item& item, const Segments& segs, std::size_t at, const std::string& value,
                std::string_view fullPath) {
    if (!item.graph) return "[!] " + item.name + " is not a graph";
    if (at >= segs.size()) return errUnknown(fullPath);
    const auto key = segs[at];
    if (key == "color") return setColor(item.graph->lineColor, segs, at + 1, value, fullPath);
    if (key == "fill_color") {
        // Animates from the EFFECTIVE color (the derived 20%-alpha fill when
        // unset), through a closure — the field lives behind an optional.
        if (at + 1 != segs.size()) return errColor(value);
        auto* graph = &*item.graph;
        return setColorVia(graph->fillColor.value_or(graph->effectiveFillColor()),
                           [graph](Color c) { graph->fillColor = c; }, value);
    }
    if (key == "line_width") return setFloat(item.graph->lineWidth, value);
    return errUnknown(fullPath);
}

Result setSlider(Item& item, const Segments& segs, std::size_t at, const std::string& value,
                 std::string_view fullPath) {
    if (!item.slider) return "[!] " + item.name + " is not a slider";
    auto& slider = *item.slider;
    if (at >= segs.size()) return errUnknown(fullPath);
    const auto key = segs[at];
    if (key == "percentage") {
        // A live drag owns the value: a routine repaint landing mid-drag must
        // not fight the pointer, and must not leave an animation running that
        // would keep fighting it after the set returns.
        if (slider.isDragged) {
            if (!parseFloat(value)) return errNumber(value);
            if (g_animation && g_animation->scheduler)
                g_animation->scheduler->cancel(animationKey());
            return ok;
        }
        return setFloatClamped(slider.percentage, value, 0.0, 100.0);
    }
    if (key == "width") {
        const auto parsed = parseFloat(value);
        if (!parsed) return errNumber(value);
        slider.width = std::max(1.0, *parsed);
        return ok;
    }
    // interactive=off: a read-only meter (battery/level gauge). Drops the
    // press/drag machinery so a click cannot rewrite the displayed value.
    if (key == "interactive") return setBool(slider.interactive, value);
    if (key == "highlight_color") return setColor(slider.highlightColor, segs, at + 1, value, fullPath);
    if (key == "knob") return setText(slider.knob, segs, at + 1, value, fullPath);
    if (key == "background") {
        if (at + 1 >= segs.size()) return errUnknown(fullPath);
        const auto sub = segs[at + 1];
        if (sub == "color") return setColor(slider.background.color, segs, at + 2, value, fullPath);
        if (sub == "height") return setFloat(slider.background.height, value);
        if (sub == "corner_radius") return setFloat(slider.background.cornerRadius, value);
        return errUnknown(fullPath);
    }
    return errUnknown(fullPath);
}

Result setGauge(Item& item, const Segments& segs, std::size_t at, const std::string& value,
                std::string_view fullPath) {
    if (!item.gauge) item.gauge.emplace(); // lazily created (ybar extension)
    auto& gauge = *item.gauge;
    if (at >= segs.size()) return errUnknown(fullPath);
    const auto key = segs[at];
    if (key == "percentage") {
        const auto parsed = parseFloat(value);
        if (!parsed) return errNumber(value);
        gauge.percentage = std::clamp(*parsed, 0.0, 100.0);
        return ok;
    }
    if (key == "size") {
        const auto parsed = parseFloat(value);
        if (!parsed) return errNumber(value);
        gauge.size = std::max(8.0, *parsed);
        return ok;
    }
    if (key == "thickness") {
        const auto parsed = parseFloat(value);
        if (!parsed) return errNumber(value);
        gauge.thickness = std::max(1.0, *parsed);
        return ok;
    }
    if (key == "color") return setColor(gauge.color, segs, at + 1, value, fullPath);
    if (key == "track_color") return setColor(gauge.trackColor, segs, at + 1, value, fullPath);
    return errUnknown(fullPath);
}

Result setImage(Item& item, const Segments& segs, std::size_t at, const std::string& value,
                std::string_view fullPath) {
    if (!item.image) item.image.emplace(); // lazily created
    auto& image = *item.image;
    if (at >= segs.size()) { image.source = value; return ok; } // bare = source
    const auto key = segs[at];
    if (key == "string") { image.source = value; return ok; }
    if (key == "drawing") {
        // Reference wording (PropertySetter.swift): `[!] invalid image.drawing:`
        // for the item-level image; background.image.drawing keeps the plain
        // boolean error. The two were swapped until the 2026-09 doc audit.
        const auto result = setBool(image.drawing, value);
        return result ? Result("[!] invalid image.drawing: " + value) : ok;
    }
    if (key == "size") {
        const auto parsed = parseFloat(value);
        if (!parsed) return errNumber(value);
        image.size = std::max(1.0, *parsed);
        return ok;
    }
    if (key == "padding_left") return setFloat(image.paddingLeft, value);
    if (key == "padding_right") return setFloat(image.paddingRight, value);
    if (key == "rotation") return setFloat(image.rotation, value);
    if (key == "y_offset") return setFloat(image.yOffset, value);
    if (key == "desaturate") return setBool(image.desaturate, value);
    if (key == "align") {
        image.align = (!value.empty() && value.front() == 'r') ? 'r' : 'l';
        return ok;
    }
    return errUnknown(fullPath);
}

Result setPopup(Item& item, const Segments& segs, std::size_t at, const std::string& value,
                std::string_view fullPath) {
    auto& popup = item.popup;
    if (at >= segs.size()) return errUnknown(fullPath);
    const auto key = segs[at];
    if (key == "drawing") return setBool(popup.isOpen, value);
    if (key == "horizontal") return setBool(popup.horizontal, value);
    if (key == "wrap_width") {
        const auto result = setFloatDirect(popup.wrapWidth, value, 0.0);
        if (result) return "[!] invalid wrap_width: " + value;
        return ok;
    }
    if (key == "auto_close") return setBool(popup.autoClose, value);
    if (key == "align") {
        const auto align = parseAlignChar(value);
        if (!align) return "[!] invalid align: " + value;
        popup.align = *align;
        return ok;
    }
    if (key == "blur_radius") return setFloat(popup.blurRadius, value);
    if (key == "topmost") return ok; // accepted-and-ignored
    if (key == "height") return setFloat(popup.cellHeight, value);
    if (key == "y_offset") return setFloat(popup.yOffset, value);
    // Durations handed to the compositor, never themselves animated — hence
    // setFloatDirect, which also clears any stray animation on the key.
    if (key == "fade_in") return setFloatDirect(popup.fadeInFrames, value, 0.0);
    if (key == "fade_out") return setFloatDirect(popup.fadeOutFrames, value, 0.0);
    if (key == "background") {
        if (at + 1 >= segs.size()) return errUnknown(fullPath);
        const auto sub = segs[at + 1];
        if (sub == "color") return setColor(popup.background.color, segs, at + 2, value, fullPath);
        if (sub == "corner_radius") return setFloat(popup.background.cornerRadius, value);
        if (sub == "border_color")
            return setColor(popup.background.borderColor, segs, at + 2, value, fullPath);
        if (sub == "border_width") return setFloat(popup.background.borderWidth, value);
        if (sub == "glass") return setBool(popup.background.glass, value);
        if (sub == "shadow" || sub == "image") return ok; // accepted-and-ignored
        return errUnknown(fullPath);
    }
    return errUnknown(fullPath);
}

Result setDisplay(Item& item, const std::string& value) {
    if (lower(value) == "active") {
        item.associatedToActiveDisplay = true;
        item.associatedDisplayMask = 0;
        return ok;
    }
    std::uint32_t mask = 0;
    std::size_t start = 0;
    const std::string list = value;
    for (std::size_t i = 0; i <= list.size(); ++i) {
        if (i == list.size() || list[i] == ',') {
            const std::string part = list.substr(start, i - start);
            start = i + 1;
            // Empty components are dropped (reference splits and ignores
            // them): "display=" and "1,2," are legal; mask 0 = all displays.
            if (part.empty()) continue;
            const auto parsed = parseInt(part);
            if (!parsed || *parsed < 1 || *parsed > 32)
                return "[!] invalid display list: " + value;
            mask |= 1u << (*parsed - 1);
        }
    }
    item.associatedToActiveDisplay = false;
    item.associatedDisplayMask = mask;
    return ok;
}

} // namespace

void PropertySetter::beginAnimation(const AnimationContext& context) {
    static AnimationContext storage;
    storage = context;
    g_animation = &storage;
}

void PropertySetter::endAnimation() { g_animation = nullptr; }

std::optional<bool> PropertySetter::parseBool(std::string_view value) {
    const auto v = lower(value);
    if (v == "on" || v == "true" || v == "yes" || v == "1") return true;
    if (v == "off" || v == "false" || v == "no" || v == "0") return false;
    return std::nullopt;
}

std::optional<std::string> PropertySetter::set(Item& item, std::string_view path,
                                               const std::string& value) {
    if (path.empty()) return "[!] empty property";
    g_currentPath = std::string(path);
    const auto segs = split(path);
    const auto key = segs[0];

    // Accepted-and-ignored item-level keys (sketchybar config compat).
    if (key == "padding_top" || key == "padding_bottom" || key == "space" ||
        key == "associated_space" || key == "ignore_association" || key == "mach_helper" ||
        key == "shadow") {
        return std::nullopt;
    }
    if (key == "alias") {
        if (segs.size() >= 2 && (segs[1] == "color" || segs[1] == "update_freq"))
            return std::nullopt; // accepted-and-ignored
        return "[!] " + item.name + " is not an alias"; // alias unsupported on Windows
    }

    if (key == "icon" || key == "label") {
        const bool isIcon = key == "icon";
        std::function<double()> measure;
        if (g_animation && g_animation->measureNaturalPartWidth)
            measure = [&item, isIcon] {
                return g_animation->measureNaturalPartWidth(item, isIcon);
            };
        return setText(isIcon ? item.icon : item.label, segs, 1, value, path, measure);
    }
    if (key == "background") return setBackground(item.background, segs, 1, value, path);
    if (key == "position") {
        const auto parsed = parsePosition(value);
        if (!parsed) return "[!] invalid position: " + value;
        item.position = *parsed;
        return std::nullopt;
    }
    if (key == "drawing") return setBool(item.drawing, value);
    if (key == "script") { item.script = value; return std::nullopt; }
    if (key == "click_script") { item.clickScript = value; return std::nullopt; }
    if (key == "update_freq") {
        const auto parsed = parseInt(value);
        if (!parsed || *parsed < 0) return "[!] invalid update_freq: " + value;
        item.updateFrequency = *parsed;
        item.routineCounter = 0;
        return std::nullopt;
    }
    if (key == "updates") {
        const auto v = lower(value);
        if (v == "when_shown") { item.updatePolicy = UpdatePolicy::WhenShown; return std::nullopt; }
        const auto parsed = parseBool(value);
        if (!parsed) return "[!] invalid updates: " + value;
        item.updatePolicy = *parsed ? UpdatePolicy::On : UpdatePolicy::Off;
        return std::nullopt;
    }
    if (key == "width") {
        std::function<double()> measure;
        if (g_animation && g_animation->measureNaturalWidth)
            measure = [&item] { return g_animation->measureNaturalWidth(item); };
        return setWidthWithDynamic(item.customWidth, value, measure);
    }
    if (key == "align") {
        const auto align = parseAlignChar(value);
        if (!align) return "[!] invalid align: " + value;
        item.align = *align;
        return std::nullopt;
    }
    if (key == "y_offset") return setFloat(item.yOffset, value);
    if (key == "padding_left") return setFloat(item.paddingLeft, value);
    if (key == "padding_right") return setFloat(item.paddingRight, value);
    if (key == "display" || key == "associated_display") return setDisplay(item, value);
    if (key == "blur_radius") return setFloat(item.blurRadius, value);
    if (key == "scroll_texts") return setBool(item.scrollTexts, value);
    if (key == "tooltip") { item.tooltip = value; return std::nullopt; }
    if (key == "graph") return setGraph(item, segs, 1, value, path);
    if (key == "slider") return setSlider(item, segs, 1, value, path);
    if (key == "gauge") return setGauge(item, segs, 1, value, path);
    if (key == "image") return setImage(item, segs, 1, value, path);
    if (key == "popup") return setPopup(item, segs, 1, value, path);

    return errUnknown(path);
}

} // namespace ybar::model
