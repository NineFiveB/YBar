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

namespace ybar::anim {
class AnimationScheduler;
}

namespace ybar::ipc {

struct DaemonHooks {
    std::function<void()> setNeedsRender;
    std::function<void(const std::string&)> reload; // optional explicit path
    std::function<void(bool)> setHotload;
    std::function<void()> exit;
    std::function<void()> forcedUpdate; // provider re-queries after --update
    // Forced-query interception for --trigger (spec 3.4); returns true when
    // the event name was intercepted and re-queried.
    std::function<bool(const std::string&)> forcedQuery;
    // Windows extension (spec 11.5): raw SocketMessage passthrough to
    // komorebi. Returns false when komorebi is unavailable.
    std::function<bool(const std::string&)> komorebiMessage;
    // `--bar wifi_ssid_prompt=on`: the Windows stand-in for the reference's
    // Core Location authorization request (spec 10).
    std::function<void()> requestSsidPermission;
    // Resolves `width=dynamic` under --animate to the measured natural width
    // (spec 3.3). Unset in headless contexts.
    std::function<double(const ybar::model::Item&)> measureNaturalWidth;
    std::function<double(const ybar::model::Item&, bool isIcon)> measureNaturalPartWidth;
    std::function<std::vector<ybar::model::DisplayInfo>()> displays;
    std::function<ybar::model::BoundingRects(const ybar::model::Item&)> boundingRects;
    // Windows extension (spec 10.6): `--query windows` lists running apps and
    // `--window <hwnd> close|kill` acts on one. Both run inline on the UI
    // thread — an enumeration pass is milliseconds, well under the IPC round
    // trip that carries it.
    std::function<std::string()> runningApps;
    std::function<std::string(long long, const std::string&)> windowAction;
    // `--query tray` lists the notification-area icons; `--tray <name> invoke`
    // activates one through UI Automation (spec 10.6).
    std::function<std::string()> trayIcons;
    std::function<std::string(const std::string&)> trayInvoke;
    std::function<std::string(const std::string&)> trayClose;
    // `--volume <0-100>` sets the default render endpoint's master volume
    // through the audio provider (spec 10, Audio row). Inline on the UI
    // thread; a WASAPI Set is microseconds.
    std::function<bool(int)> setVolume;
    // Per-app sessions (spec 10, Audio row): `--query audio` lists the
    // default endpoint's session groups; `--volume <0-100> <app>` sets one
    // group. Both are stateless enumeration passes inline on the UI thread.
    std::function<std::string()> audioSessions;
    std::function<bool(const std::string&, int)> setAppVolume;
};

class CommandHandler {
public:
    CommandHandler(ybar::model::ItemStore& store, ybar::model::BarSettings& settings,
                   ybar::events::EventBus& bus, DaemonHooks hooks,
                   ybar::anim::AnimationScheduler* scheduler = nullptr);

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
    ybar::anim::AnimationScheduler* scheduler_;
};

} // namespace ybar::ipc
