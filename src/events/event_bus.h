// Named events over a per-item u64 subscription bitmask (spec section 3.4).
// The 20 built-in names and their declaration order are wire contract —
// --query exposes raw update_mask values.

#pragma once

#include <cstdint>
#include <functional>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "model/item.h"

namespace ybar::events {

// env passed to script/Lua dispatch; NAME/SENDER/INFO are applied last and
// cannot be spoofed by --trigger extras.
using Environment = std::map<std::string, std::string>;

class EventBus {
public:
    static constexpr int kMaxEvents = 64;
    static const std::vector<std::string>& builtinEvents();

    EventBus();

    // Items to consider on bus-wide triggers.
    std::function<std::vector<ybar::model::Item*>()> itemsProvider;
    // Dispatch one item's handler with the merged environment.
    std::function<void(ybar::model::Item&, const Environment&)> runItemScript;
    // Lazy provider arming on the FIRST subscription of an event name.
    std::function<void(const std::string&)> onFirstSubscription;

    // nullopt on success (duplicate add is a silent no-op);
    // "[!] event limit reached (64)" at the cap. The notification binding
    // argument is accepted and recorded but has no Windows backend (spec 9).
    std::optional<std::string> addEvent(const std::string& name,
                                       const std::string& notification = {});

    bool knownEvent(std::string_view name) const;
    std::optional<std::uint64_t> eventBit(std::string_view name) const;

    // false when the event is unknown.
    bool subscribe(ybar::model::Item& item, std::string_view eventName);

    // Bus-wide trigger, gated by the updates policy; only items with a script
    // or Lua handlers receive it.
    void trigger(std::string_view eventName, const std::string& info,
                 const Environment& extraEnvironment = {});

    // Targeted dispatch (mouse events): only the given item, no policy gate.
    void triggerTargeted(ybar::model::Item& item, std::string_view eventName,
                         const std::string& info, const Environment& extraEnvironment = {});

    // Drops custom events, re-registers built-ins in identical order.
    void reset();

    struct Definition {
        std::string name;
        std::uint64_t bit = 0;
        std::string notification; // recorded for --query events ("(null)" when empty)
    };
    const std::vector<Definition>& definitions() const { return definitions_; }

private:
    std::vector<Definition> definitions_;
    std::vector<bool> armed_; // first-subscription tracking per definition
};

} // namespace ybar::events
