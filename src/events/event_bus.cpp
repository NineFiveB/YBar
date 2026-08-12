#include "events/event_bus.h"

namespace ybar::events {

using ybar::model::Item;
using ybar::model::UpdatePolicy;

const std::vector<std::string>& EventBus::builtinEvents() {
    // Exact declaration order fixes bit values — contract (spec 3.4).
    static const std::vector<std::string> events = {
        "front_app_switched", "space_change", "display_change", "system_woke",
        "system_will_sleep", "mouse.entered", "mouse.exited", "mouse.clicked",
        "mouse.scrolled", "volume_change", "power_source_change", "battery_change",
        "wifi_change", "system_stats", "mouse.exited.global", "mouse.entered.global",
        "modifier_change", "app_launched", "app_terminated", "media_change",
    };
    return events;
}

EventBus::EventBus() { reset(); }

void EventBus::reset() {
    definitions_.clear();
    armed_.clear();
    for (const auto& name : builtinEvents()) {
        definitions_.push_back({name, 1ull << definitions_.size(), {}});
        armed_.push_back(false);
    }
}

std::optional<std::string> EventBus::addEvent(const std::string& name,
                                              const std::string& notification) {
    if (knownEvent(name)) return std::nullopt; // duplicate add is a silent no-op
    if (definitions_.size() >= kMaxEvents) return "[!] event limit reached (64)";
    definitions_.push_back({name, 1ull << definitions_.size(), notification});
    armed_.push_back(false);
    return std::nullopt;
}

bool EventBus::knownEvent(std::string_view name) const {
    return eventBit(name).has_value();
}

std::optional<std::uint64_t> EventBus::eventBit(std::string_view name) const {
    for (const auto& def : definitions_)
        if (def.name == name) return def.bit;
    return std::nullopt;
}

bool EventBus::subscribe(Item& item, std::string_view eventName) {
    for (std::size_t i = 0; i < definitions_.size(); ++i) {
        if (definitions_[i].name != eventName) continue;
        item.updateMask |= definitions_[i].bit;
        if (!armed_[i] && onFirstSubscription) {
            armed_[i] = true;
            onFirstSubscription(definitions_[i].name);
        }
        return true;
    }
    return false;
}

namespace {

Environment merged(const Environment& extra, const Item& item, std::string_view sender,
                   const std::string& info) {
    Environment env = extra;
    // Applied LAST — a --trigger payload can never clobber these.
    env["NAME"] = item.name;
    env["SENDER"] = std::string(sender);
    env["INFO"] = info;
    return env;
}

} // namespace

void EventBus::trigger(std::string_view eventName, const std::string& info,
                       const Environment& extraEnvironment) {
    const auto bit = eventBit(eventName);
    if (!bit || !itemsProvider || !runItemScript) return;
    for (auto* item : itemsProvider()) {
        if (!(item->updateMask & *bit)) continue;
        if (item->script.empty() && !item->hasLuaHandlers) continue;
        if (item->updatePolicy == UpdatePolicy::Off) continue;
        if (item->updatePolicy == UpdatePolicy::WhenShown && !item->drawing) continue;
        runItemScript(*item, merged(extraEnvironment, *item, eventName, info));
    }
}

void EventBus::triggerTargeted(Item& item, std::string_view eventName, const std::string& info,
                               const Environment& extraEnvironment) {
    // Mouse events bypass the updates-POLICY gate, but the subscription mask
    // still governs delivery (spec 3.4) — otherwise every scripted item fires
    // on any hover/click.
    if (!runItemScript) return;
    const auto bit = eventBit(eventName);
    if (!bit || !(item.updateMask & *bit)) return;
    if (item.script.empty() && !item.hasLuaHandlers) return;
    runItemScript(item, merged(extraEnvironment, item, eventName, info));
}

} // namespace ybar::events
