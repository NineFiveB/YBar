#include "ipc/command_handler.h"

#include <charconv>

#include "model/property_setter.h"

namespace ybar::ipc {

using ybar::events::Environment;
using ybar::model::BarPropertySetter;
using ybar::model::Item;
using ybar::model::ItemKind;
using ybar::model::ItemPosition;
using ybar::model::PropertySetter;

namespace {

std::optional<int> parseInt(const std::string& value) {
    int parsed = 0;
    const auto [ptr, ec] = std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (ec != std::errc() || ptr != value.data() + value.size() || value.empty())
        return std::nullopt;
    return parsed;
}

std::optional<double> parseFloat(const std::string& value) {
    double parsed = 0;
    const auto [ptr, ec] = std::from_chars(value.data(), value.data() + value.size(), parsed);
    if (ec != std::errc() || ptr != value.data() + value.size() || value.empty())
        return std::nullopt;
    return parsed;
}

// "left|right|center|q|e|popup.<host>" — the --add position grammar.
struct ParsedPosition {
    ItemPosition position;
    std::string popupHost;
};

std::optional<ParsedPosition> parseAddPosition(const std::string& token) {
    if (token.rfind("popup.", 0) == 0 && token.size() > 6)
        return ParsedPosition{ItemPosition::Popup, token.substr(6)};
    if (const auto parsed = ybar::model::parsePosition(token))
        return ParsedPosition{*parsed, {}};
    return std::nullopt;
}

} // namespace

CommandHandler::CommandHandler(ybar::model::ItemStore& store, ybar::model::BarSettings& settings,
                               ybar::events::EventBus& bus, DaemonHooks hooks)
    : store_(store), settings_(settings), bus_(bus), hooks_(std::move(hooks)) {}

std::string CommandHandler::handle(const std::vector<std::string>& argv) {
    std::optional<AnimationScope> animation; // message-scoped
    std::vector<std::string> outputs;
    for (const auto& batch : parse(argv)) {
        auto output = handleBatch(batch, animation);
        if (!output.empty()) outputs.push_back(std::move(output));
    }
    std::string joined;
    for (std::size_t i = 0; i < outputs.size(); ++i) {
        if (i) joined += "\n";
        joined += outputs[i];
    }
    if (hooks_.setNeedsRender) hooks_.setNeedsRender();
    return joined;
}

std::string CommandHandler::handleBatch(const Batch& batch,
                                        std::optional<AnimationScope>& animation) {
    const auto& args = batch.args;

    if (batch.domain == "ping") return "pong";

    if (batch.domain == "animate") {
        if (args.size() != 2) return "[!] usage: --animate <curve> <duration-frames>";
        const auto frames = parseInt(args[1]);
        if (!frames || *frames < 0) return "[!] usage: --animate <curve> <duration-frames>";
        animation = AnimationScope{args[0], *frames};
        return {};
    }

    if (batch.domain == "bar") {
        for (const auto& token : args) {
            const auto [key, value] = keyValue(token);
            if (value.empty() && token.find('=') == std::string::npos)
                return "[!] expected key=value, got: " + token;
            if (const auto error = BarPropertySetter::set(settings_, key, value)) return *error;
        }
        return {};
    }

    if (batch.domain == "default") {
        if (args.size() == 1 && args[0] == "reset") {
            store_.resetDefaults();
            return {};
        }
        for (const auto& token : args) {
            const auto [key, value] = keyValue(token);
            if (value.empty() && token.find('=') == std::string::npos)
                return "[!] expected key=value, got: " + token;
            // --default never animates (contract).
            if (const auto error = PropertySetter::set(store_.defaults(), key, value))
                return *error;
        }
        return {};
    }

    if (batch.domain == "add") {
        if (args.empty()) return "[!] --add needs a type";
        const auto& kind = args[0];
        if (kind == "item") {
            if (args.size() != 3) return "[!] usage: --add item <name> <position>";
            const auto position = parseAddPosition(args[2]);
            if (!position) return "[!] invalid position or duplicate name: " + args[1] + " " + args[2];
            auto* item = store_.add(args[1], position->position);
            if (!item) return "[!] invalid position or duplicate name: " + args[1] + " " + args[2];
            if (position->position == ItemPosition::Popup) {
                if (!store_.find(position->popupHost)) {
                    store_.remove(args[1]);
                    return "[!] invalid position or duplicate name: " + args[1] + " " + args[2];
                }
                item->popupHost = position->popupHost;
            }
            return {};
        }
        if (kind == "graph") {
            if (args.size() != 4) return "[!] usage: --add graph <name> <position> <width> (1...8192)";
            const auto position = parseAddPosition(args[2]);
            const auto width = parseInt(args[3]);
            if (!position || !width || *width < 1 || *width > 8192)
                return "[!] usage: --add graph <name> <position> <width> (1...8192)";
            auto* item = store_.add(args[1], position->position, ItemKind::Graph);
            if (!item) return "[!] usage: --add graph <name> <position> <width> (1...8192)";
            item->popupHost = position->popupHost;
            item->graph.emplace();
            item->graph->capacity = *width;
            return {};
        }
        if (kind == "slider") {
            if (args.size() != 4) return "[!] usage: --add slider <name> <position> <width>";
            const auto position = parseAddPosition(args[2]);
            const auto width = parseFloat(args[3]);
            if (!position || !width || *width <= 0)
                return "[!] usage: --add slider <name> <position> <width>";
            auto* item = store_.add(args[1], position->position, ItemKind::Slider);
            if (!item) return "[!] usage: --add slider <name> <position> <width>";
            item->popupHost = position->popupHost;
            item->slider.emplace();
            item->slider->width = *width;
            return {};
        }
        if (kind == "bracket") {
            if (args.size() < 3) return "[!] usage: --add bracket <name> <member>...";
            std::vector<std::string> members(args.begin() + 2, args.end());
            std::string unknown;
            for (const auto& member : members) {
                if (store_.matching(member).empty()) {
                    if (!unknown.empty()) unknown += ", ";
                    unknown += member;
                }
            }
            if (!unknown.empty()) return "[!] unknown bracket members: " + unknown;
            auto* item = store_.add(args[1], ItemPosition::Left, ItemKind::Bracket);
            if (!item) return "[!] item " + args[1] + " already exists";
            item->members = std::move(members);
            item->background.drawing = true;
            return {};
        }
        if (kind == "event") {
            if (args.size() < 2 || args.size() > 3)
                return "[!] usage: --add event <name> [notification]";
            if (const auto error = bus_.addEvent(args[1], args.size() == 3 ? args[2] : ""))
                return *error;
            return {};
        }
        if (kind == "alias") return "[!] alias items are not supported on Windows";
        return "[!] unknown --add type: " + kind + " (supported: item, graph, slider, bracket, event)";
    }

    if (batch.domain == "set") {
        if (args.empty()) return "[!] --set needs an item name";
        const auto matches = store_.matching(args[0]);
        if (matches.empty()) return "[!] no item matching " + args[0];
        for (std::size_t i = 1; i < args.size(); ++i) {
            const auto& token = args[i];
            const auto [key, value] = keyValue(token);
            if (value.empty() && token.find('=') == std::string::npos)
                return "[!] expected key=value, got: " + token;
            for (auto* item : matches) {
                // TODO(animation slice): route through the scheduler when
                // `animation` is set; direct set for now.
                if (const auto error = PropertySetter::set(*item, key, value)) return *error;
            }
        }
        return {};
    }

    if (batch.domain == "subscribe") {
        if (args.empty()) return "[!] --subscribe needs an item name";
        auto* item = store_.find(args[0]);
        if (!item) return "[!] no item named " + args[0];
        for (std::size_t i = 1; i < args.size(); ++i) {
            if (!bus_.subscribe(*item, args[i])) return "[!] unknown event: " + args[i];
        }
        return {};
    }

    if (batch.domain == "trigger") {
        if (args.empty()) return "[!] --trigger needs an event name";
        const auto& event = args[0];
        if (hooks_.forcedQuery && hooks_.forcedQuery(event)) return {};
        Environment extra;
        std::string info;
        for (std::size_t i = 1; i < args.size(); ++i) {
            const auto [key, value] = keyValue(args[i]);
            if (key == "INFO") info = value;
            extra[key] = value;
        }
        bus_.trigger(event, info, extra);
        return {};
    }

    if (batch.domain == "update") {
        if (bus_.runItemScript) {
            for (const auto& item : store_.items()) {
                if (item->script.empty() && !item->hasLuaHandlers) continue;
                // --update bypasses the updates policy (contract).
                Environment env{{"NAME", item->name}, {"SENDER", "forced"}, {"INFO", ""}};
                bus_.runItemScript(*item, env);
            }
        }
        if (hooks_.forcedUpdate) hooks_.forcedUpdate();
        return {};
    }

    if (batch.domain == "query") {
        if (args.size() != 1) return "[!] --query needs a target";
        const auto& target = args[0];
        if (target == "bar") return ybar::model::serializeBar(settings_, store_);
        if (target == "defaults") return ybar::model::serializeDefaults(store_.defaults());
        if (target == "events") return ybar::model::serializeEvents(bus_);
        if (target == "displays")
            return ybar::model::serializeDisplays(hooks_.displays ? hooks_.displays()
                                                                  : std::vector<ybar::model::DisplayInfo>{});
        auto* item = store_.find(target);
        if (!item) return "[!] no item named " + target;
        return ybar::model::serializeItem(
            *item, hooks_.boundingRects ? hooks_.boundingRects(*item) : ybar::model::BoundingRects{});
    }

    if (batch.domain == "push") {
        if (args.empty()) return "[!] --push needs a graph item name";
        auto* item = store_.find(args[0]);
        if (!item || !item->graph) return "[!] --push needs a graph item name";
        for (std::size_t i = 1; i < args.size(); ++i) {
            const auto value = parseFloat(args[i]);
            if (!value) return "[!] invalid graph value: " + args[i];
            item->graph->push(*value);
        }
        return {};
    }

    if (batch.domain == "remove") {
        if (args.size() != 1) return "[!] --remove needs an item name";
        if (!store_.remove(args[0])) return "[!] no item matching " + args[0];
        return {};
    }

    if (batch.domain == "move") {
        if (args.size() != 3 || (args[1] != "before" && args[1] != "after"))
            return "[!] usage: --move <name> before|after <anchor>";
        if (!store_.move(args[0], args[1] == "before", args[2]))
            return "[!] could not move " + args[0];
        return {};
    }

    if (batch.domain == "reorder") {
        if (!store_.reorder(args)) return "[!] could not reorder (unknown names?)";
        return {};
    }

    if (batch.domain == "rename") {
        if (args.size() != 2) return "[!] usage: --rename <old> <new>";
        if (!store_.rename(args[0], args[1])) return "[!] could not rename " + args[0];
        return {};
    }

    if (batch.domain == "clone") {
        if (args.size() < 2 || args.size() > 3)
            return "[!] usage: --clone <new-name> <source> [before|after]";
        const bool before = args.size() == 3 && args[2] == "before";
        if (args.size() == 3 && args[2] != "before" && args[2] != "after")
            return "[!] usage: --clone <new-name> <source> [before|after]";
        if (!store_.clone(args[0], args[1], before)) return "[!] could not clone " + args[1];
        return {};
    }

    if (batch.domain == "reload") {
        if (hooks_.reload) hooks_.reload();
        return {};
    }

    if (batch.domain == "hotload") {
        if (args.size() != 1) return "[!] usage: --hotload <on|off>";
        const auto parsed = PropertySetter::parseBool(args[0]);
        if (!parsed) return "[!] usage: --hotload <on|off>";
        if (hooks_.setHotload) hooks_.setHotload(*parsed);
        return {};
    }

    if (batch.domain == "komorebi") { // ybar-win extension (spec 11.5)
        if (args.size() != 1) return "[!] usage: --komorebi <socket-message-json>";
        if (!hooks_.komorebiMessage || !hooks_.komorebiMessage(args[0]))
            return "[!] komorebi is not available";
        return {};
    }

    if (batch.domain == "exit") {
        if (hooks_.exit) hooks_.exit();
        return {};
    }

    return "[!] unknown domain: --" + batch.domain;
}

} // namespace ybar::ipc
