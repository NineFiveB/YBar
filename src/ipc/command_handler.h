// Executes parsed domain batches against the model — all 19 verbs with the
// reference usage/error strings (spec section 3.2). Platform effects (render,
// providers, reload, exit) are injected hooks so the handler stays testable
// headless.

#pragma once

#include <functional>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "events/event_bus.h"
#include "ipc/command_parser.h"
#include "model/bar_settings.h"
#include "model/item.h"
#include "model/serialize.h"

namespace ybar::ipc {

struct DaemonHooks {
    std::function<void()> setNeedsRender;
    std::function<void()> reload;
    std::function<void(bool)> setHotload;
    std::function<void()> exit;
    std::function<void()> forcedUpdate; // provider re-queries after --update
    // Forced-query interception for --trigger (spec 3.4); returns true when
    // the event name was intercepted and re-queried.
    std::function<bool(const std::string&)> forcedQuery;
    std::function<std::vector<ybar::model::DisplayInfo>()> displays;
    std::function<ybar::model::BoundingRects(const ybar::model::Item&)> boundingRects;
};

class CommandHandler {
public:
    CommandHandler(ybar::model::ItemStore& store, ybar::model::BarSettings& settings,
                   ybar::events::EventBus& bus, DaemonHooks hooks);

    // Handles one client message; batch outputs joined with "\n".
    std::string handle(const std::vector<std::string>& argv);

private:
    struct AnimationScope {
        std::string curve;
        int frames = 0;
    };

    std::string handleBatch(const Batch& batch, std::optional<AnimationScope>& animation);

    ybar::model::ItemStore& store_;
    ybar::model::BarSettings& settings_;
    ybar::events::EventBus& bus_;
    DaemonHooks hooks_;
};

} // namespace ybar::ipc
