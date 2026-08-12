#include "app/daemon.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
#include <shobjidl.h> // SetCurrentProcessExplicitAppUserModelID
// clang-format on

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <memory>
#include <unordered_map>
#include <utility>

#include "anim/scheduler.h"
#include "app/config.h"
#include "app/jsonc_config.h"
#include "app/script_runner.h"
#include "events/event_bus.h"
#include "ipc/command_handler.h"
#include "ipc/socket.h"
#include "ipc/wire_format.h"
#include "lua/runtime.h"
#include "model/bar_settings.h"
#include "model/item.h"
#include "model/layout.h"
#include "providers/app_info.h"
#include "providers/app_lifecycle.h"
#include "providers/audio.h"
#include "providers/komorebi.h"
#include "providers/media.h"
#include "providers/network.h"
#include "providers/ytile.h"
#include "render/font_cache.h"
#include "render/glyph_atlas.h"
#include "render/renderer.h"
#include "render/scene_builder.h"
#include "model/popup_layout.h"
#include "win/bar_surface.h"
#include "win/display_manager.h"
#include "win/input.h"
#include "win/popup_surface.h"

namespace ybar::app {

namespace {

// YBAR_DEBUG=1 traces daemon bring-up to stderr (crash-site bisection).
void trace(const char* stage) {
    static const bool enabled = std::getenv("YBAR_DEBUG") != nullptr;
    if (enabled) {
        std::fprintf(stderr, "[ybar:init] %s\n", stage);
        std::fflush(stderr);
    }
}

constexpr UINT kMsgIpcRequest = WM_APP + 1;
constexpr UINT kMsgRender = WM_APP + 2;
constexpr UINT kMsgKomorebi = WM_APP + 3;
constexpr UINT kMsgReloadConfig = WM_APP + 4;
constexpr UINT kMsgYTile = WM_APP + 6; // +5 is Lua's kMsgExecDone
constexpr UINT kMsgCloseAutoPopups = WM_APP + 7;
constexpr UINT kMsgVolume = WM_APP + 8;
constexpr UINT kMsgMedia = WM_APP + 9;
constexpr UINT kMsgNetwork = WM_APP + 10;
constexpr UINT kMsgModifier = WM_APP + 11;
constexpr UINT kMsgGlobalMouse = WM_APP + 12; // wParam: 1 entered, 0 exited
constexpr UINT kMsgKomorebiApp = WM_APP + 13;
constexpr UINT_PTR kStatsTimer = 5;
constexpr UINT_PTR kTooltipTimer = 6;
constexpr UINT_PTR kAppsTimer = 7;
constexpr UINT_PTR kDisplayChangeTimer = 8;

// Power setting GUIDs (winnt.h declares them; define locally to avoid
// link-time surprises with initguid ordering).
constexpr GUID kGuidAcDcPowerSource = {
    0x5d3e9a59, 0xe9d5, 0x4b00, {0xa6, 0xbd, 0xff, 0x34, 0xff, 0x51, 0x65, 0x48}};
constexpr GUID kGuidBatteryPercentage = {
    0xa7ad8041, 0xb45a, 0x4cae, {0x87, 0xa3, 0xee, 0xcb, 0xb4, 0x68, 0xa9, 0xe1}};
constexpr UINT_PTR kRoutineTimer = 1;
constexpr UINT_PTR kExitTimer = 2;
constexpr UINT_PTR kRenderRetryTimer = 3;
constexpr UINT_PTR kAnimationTimer = 4;

double monotonicSeconds() {
    static const double frequency = [] {
        LARGE_INTEGER f;
        QueryPerformanceFrequency(&f);
        return static_cast<double>(f.QuadPart);
    }();
    LARGE_INTEGER counter;
    QueryPerformanceCounter(&counter);
    return static_cast<double>(counter.QuadPart) / frequency;
}

struct IpcRequest {
    std::vector<std::string> argv;
    std::promise<std::string> reply;
};

struct DaemonState {
    ybar::model::ItemStore store;
    ybar::model::BarSettings settings;
    ybar::events::EventBus bus;
    std::unique_ptr<ybar::ipc::CommandHandler> handler;
    HWND messageWindow = nullptr;

    // Rendering (absent when the GPU stack failed — daemon still serves IPC).
    std::unique_ptr<ybar::render::Renderer> renderer;
    std::unique_ptr<ybar::render::FontCache> fonts;
    std::vector<std::unique_ptr<ybar::win::BarSurface>> surfaces;
    std::unordered_map<int, std::unique_ptr<ybar::render::GlyphAtlas>> atlases; // key: scale*100
    bool renderQueued = false;

    ScriptRunner scripts;
    std::unique_ptr<ybar::providers::KomorebiProvider> komorebi;
    std::unique_ptr<ybar::providers::YTileProvider> ytile;
    // Lazily armed on first subscription (spec 10) — a config that never
    // mentions these events pays nothing for them.
    std::unique_ptr<ybar::providers::AudioProvider> audio;
    std::unique_ptr<ybar::providers::MediaProvider> media;
    std::unique_ptr<ybar::providers::NetworkProvider> network;
    ybar::providers::AppLifecycleProvider appLifecycle;
    bool appLifecycleArmed = false;
    ybar::anim::AnimationScheduler scheduler;
    bool animationTimerLive = false;
    int appliedOffsetPhysical = -1;
    int hoverItemId = -1; // targeted mouse.entered/exited tracking

    // Config (spec 5).
    std::string instance;
    std::string explicitConfigPath;
    std::string resolvedConfigPath;
    Hotload hotload;
    std::unique_ptr<ybar::lua::LuaRuntime> lua;

    // Popups & tooltip (spec 3.9): one panel per open host, keyed by item id.
    struct LivePopup {
        std::unique_ptr<ybar::win::PopupSurface> surface;
        std::vector<int> memberIds;
        std::vector<ybar::model::Rect> boxes; // panel-local logical
    };
    std::unordered_map<int, LivePopup> popups;
    std::unique_ptr<ybar::win::PopupSurface> tooltip;
    int tooltipItemId = -1;
    void* mouseHook = nullptr;    // HHOOK (WH_MOUSE_LL) for outside-click close
    void* keyboardHook = nullptr; // HHOOK (WH_KEYBOARD_LL), modifier_change only
    // Global pointer tracking (mouse.entered.global / mouse.exited.global) is
    // the union over every ybar window, so it rides the existing low-level
    // hook rather than per-window WM_MOUSELEAVE.
    bool globalMouseArmed = false;
    bool globalMouseInside = false;
    std::string lastModifier = "none";

    // Providers (spec 10): dedupe state.
    std::string lastPowerSource;
    int lastBatteryPercent = -1;
    std::string lastFrontApp;
    ULONGLONG statsPrevIdle = 0, statsPrevKernel = 0, statsPrevUser = 0;
    bool statsArmed = false;

    // Attached to every surface, including ones built by a display-change
    // rebuild — so it outlives any single surface set. The index identifies
    // which surface the event came from.
    std::function<void(std::size_t, const ybar::win::MouseEvent&)> mouseHandler;

    // Item frames per surface, parallel to `surfaces`. Layout runs once per
    // surface and monitors can differ in width, so a single shared frame set
    // would hit-test monitor 2 against monitor 1's geometry and report the
    // last-rendered monitor's rects for every display in bounding_rects.
    std::vector<std::unordered_map<int, ybar::model::Rect>> surfaceFrames;

    const ybar::model::Rect* frameFor(std::size_t surfaceIndex, int itemId) const {
        if (surfaceIndex >= surfaceFrames.size()) return nullptr;
        const auto& frames = surfaceFrames[surfaceIndex];
        const auto it = frames.find(itemId);
        return it == frames.end() ? nullptr : &it->second;
    }

    void attachMouseHandlers() {
        for (std::size_t i = 0; i < surfaces.size(); ++i) {
            surfaces[i]->setMouseHandler(
                [this, i](const ybar::win::MouseEvent& event) {
                    if (mouseHandler) mouseHandler(i, event);
                });
        }
    }

    void executeConfig();
    void rebuildSurfaces();
    bool tryAttachKomorebi();
    void updateFullscreenElevation();
    void armAudio();
    void armMedia();
    void armNetwork();
    void publishPower(bool forced);
    void publishFrontApp(bool forced);
    void sampleStats();
    void updatePopups();
    void closeAutoClosePopups(int exceptHostId);
    void dispatchClick(ybar::model::Item& item, const char* button, const char* modifier);

    // Slider dragging (spec 3.9): the item captured on press keeps receiving
    // motion until release, even past its own frame.
    int draggingSliderId = -1;
    void updateSlider(ybar::model::Item& item, std::size_t surfaceIndex, double localX);
    void showTooltip(ybar::model::Item& item);
    void hideTooltip();
    ybar::model::MeasuredContent measureItem(const ybar::model::Item& item) {
        ybar::model::MeasuredContent m;
        const auto& icon = fonts->shape(item.icon.displayString(), item.icon.font);
        const auto& label = fonts->shape(item.label.displayString(), item.label.font);
        m.icon = {icon.width, icon.measuredHeight()};
        m.label = {label.width, label.measuredHeight()};
        return m;
    }

    // On-demand frame clock: runs while animations exist OR a marquee is on
    // screen (continuousDemand, spec 7.2) — never otherwise.
    bool marqueeOnScreen = false;
    void syncAnimationTimer() {
        const bool wanted = scheduler.active() || marqueeOnScreen;
        if (wanted && !animationTimerLive) {
            SetTimer(messageWindow, kAnimationTimer, 16, nullptr);
            animationTimerLive = true;
            return;
        }
        if (!wanted && animationTimerLive) {
            KillTimer(messageWindow, kAnimationTimer);
            animationTimerLive = false;
            return;
        }
    }

    ybar::render::GlyphAtlas* atlasFor(double scale) {
        const int key = static_cast<int>(scale * 100 + 0.5);
        auto it = atlases.find(key);
        if (it != atlases.end()) return it->second.get();
        auto atlas = ybar::render::GlyphAtlas::create(renderer->deviceRaw(),
                                                      renderer->contextRaw(), scale);
        if (!atlas) return nullptr;
        return atlases.emplace(key, std::move(atlas)).first->second.get();
    }

    void renderAll();
};

DaemonState* g_state = nullptr;

std::string exeDirectory() {
    wchar_t buffer[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    std::wstring path(buffer, n);
    const auto slash = path.find_last_of(L"\\/");
    path = slash == std::wstring::npos ? L"." : path.substr(0, slash);
    const int size = WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1, nullptr, 0, nullptr,
                                         nullptr);
    std::string utf8(static_cast<std::size_t>(size - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, path.c_str(), -1, utf8.data(), size, nullptr, nullptr);
    return utf8;
}

LRESULT CALLBACK messageWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case kMsgIpcRequest: {
            auto* request = reinterpret_cast<IpcRequest*>(lParam);
            std::string reply;
            if (g_state && g_state->handler) reply = g_state->handler->handle(request->argv);
            request->reply.set_value(std::move(reply));
            delete request;
            return 0;
        }
        case kMsgRender:
            if (g_state) {
                g_state->renderQueued = false;
                g_state->renderAll();
                g_state->syncAnimationTimer(); // marquee may have appeared
            }
            return 0;
        case kMsgKomorebi: {
            auto* update = reinterpret_cast<ybar::providers::KomorebiUpdate*>(lParam);
            if (g_state) {
                ybar::events::Environment env{
                    {"FOCUSED_WORKSPACE", update->focusedWorkspace},
                    {"PREV_WORKSPACE", update->previousWorkspace},
                    {"FOCUSED_MONITOR_INDEX",
                     std::to_string(update->focusedMonitorIndex + 1)},
                };
                g_state->bus.trigger("komorebi_workspace_change", update->focusedWorkspace,
                                     env);
                g_state->bus.trigger("space_change", "", env);
            }
            delete update;
            return 0;
        }
        case kMsgYTile: {
            auto* update = reinterpret_cast<ybar::providers::YTileUpdate*>(lParam);
            if (g_state) {
                ybar::events::Environment env{
                    {"FOCUSED_WORKSPACE", update->focusedWorkspace},
                    {"PREV_WORKSPACE", update->previousWorkspace},
                    {"FOCUSED_MONITOR_INDEX",
                     std::to_string(update->focusedMonitorIndex + 1)},
                };
                // komorebi_workspace_change fires too so existing configs and
                // themes keep working unchanged, whichever WM is running.
                g_state->bus.trigger("ytile_workspace_change", update->focusedWorkspace, env);
                g_state->bus.trigger("komorebi_workspace_change", update->focusedWorkspace,
                                     env);
                g_state->bus.trigger("space_change", "", env);
            }
            delete update;
            return 0;
        }
        case WM_TIMER:
            if (wParam == kRoutineTimer && g_state) {
                // Gate BEFORE incrementing (reference ordering): policy-off or
                // hidden items must not advance their counters, or re-enabling
                // fires at a different phase.
                for (const auto& item : g_state->store.items()) {
                    if (item->updateFrequency <= 0) continue;
                    if (item->script.empty() && !item->hasLuaHandlers) continue;
                    if (item->updatePolicy == ybar::model::UpdatePolicy::Off) continue;
                    if (item->updatePolicy == ybar::model::UpdatePolicy::WhenShown &&
                        !item->drawing)
                        continue;
                    if (++item->routineCounter < item->updateFrequency) continue;
                    item->routineCounter = 0;
                    if (g_state->bus.runItemScript) {
                        g_state->bus.runItemScript(
                            *item, {{"NAME", item->name}, {"SENDER", "routine"}, {"INFO", ""}});
                    }
                }
                // Per-second upkeep: none of these have a message to hang off.
                g_state->updateFullscreenElevation();
                g_state->tryAttachKomorebi(); // komorebi may have just started
                if (g_state->settings.sticky) {
                    for (const auto& surface : g_state->surfaces) surface->followCurrentDesktop();
                }
                // idle_inhibit: the request must be re-stated, it is not a
                // latch that survives a reboot of the power policy.
                if (g_state->settings.idleInhibit)
                    SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED |
                                            ES_SYSTEM_REQUIRED);
                else
                    SetThreadExecutionState(ES_CONTINUOUS);
            } else if (wParam == kExitTimer) {
                KillTimer(hwnd, kExitTimer);
                if (g_state && g_state->komorebi) {
                    g_state->komorebi->clearWorkAreaOffset(); // spec 11.4
                    g_state->komorebi->stop();
                }
                if (g_state && g_state->ytile) {
                    g_state->ytile->clearWorkAreaOffset();
                    g_state->ytile->stop();
                }
                PostQuitMessage(0);
            } else if (wParam == kRenderRetryTimer && g_state) {
                KillTimer(hwnd, kRenderRetryTimer);
                g_state->renderAll();
            } else if (wParam == kAnimationTimer && g_state) {
                g_state->scheduler.tick(monotonicSeconds());
                g_state->renderAll();
                g_state->syncAnimationTimer();
            } else if (wParam == kStatsTimer && g_state) {
                g_state->sampleStats();
            } else if (wParam == kAppsTimer && g_state) {
                g_state->appLifecycle.sample();
            } else if (wParam == kDisplayChangeTimer && g_state) {
                KillTimer(hwnd, kDisplayChangeTimer);
                g_state->rebuildSurfaces();
                g_state->bus.trigger("display_change",
                                     std::to_string(ybar::win::enumerateMonitors().size()));
            } else if (wParam == kTooltipTimer && g_state) {
                KillTimer(hwnd, kTooltipTimer);
                if (g_state->hoverItemId == g_state->tooltipItemId) {
                    for (const auto& item : g_state->store.items()) {
                        if (item->id == g_state->tooltipItemId && !item->tooltip.empty()) {
                            g_state->showTooltip(*item);
                            break;
                        }
                    }
                }
            } else if (g_state && g_state->lua && g_state->lua->onTimer(wParam)) {
                // ybar.delay timers.
            }
            return 0;
        case ybar::lua::LuaRuntime::kMsgExecDone: {
            auto* result = reinterpret_cast<ybar::lua::LuaRuntime::ExecResult*>(lParam);
            if (g_state && g_state->lua) g_state->lua->completeExec(*result);
            delete result;
            return 0;
        }
        case kMsgCloseAutoPopups:
            if (g_state) g_state->closeAutoClosePopups(-1);
            return 0;
        case kMsgVolume:
            if (g_state) g_state->bus.trigger("volume_change",
                                              std::to_string(static_cast<int>(wParam)));
            return 0;
        case kMsgNetwork: {
            auto* info = reinterpret_cast<std::string*>(lParam);
            if (g_state) g_state->bus.trigger("wifi_change", *info);
            delete info;
            return 0;
        }
        case kMsgMedia: {
            auto* env = reinterpret_cast<ybar::providers::MediaEnvironment*>(lParam);
            if (g_state) {
                const auto state = env->find("MEDIA_STATE");
                g_state->bus.trigger("media_change",
                                     state == env->end() ? "" : state->second, *env);
            }
            delete env;
            return 0;
        }
        case kMsgKomorebiApp: {
            auto* payload = reinterpret_cast<std::pair<std::string, std::string>*>(lParam);
            if (g_state) {
                const std::string name =
                    ybar::providers::appNameForExecutablePath(payload->second);
                if (!name.empty()) g_state->bus.trigger(payload->first, name);
            }
            delete payload;
            return 0;
        }
        case kMsgModifier:
            if (g_state) {
                const std::string modifier = ybar::win::currentModifierAsync();
                if (modifier != g_state->lastModifier) {
                    g_state->lastModifier = modifier;
                    g_state->bus.trigger("modifier_change", "", {{"MODIFIER", modifier}});
                }
            }
            return 0;
        case kMsgGlobalMouse:
            if (g_state)
                g_state->bus.trigger(wParam ? "mouse.entered.global" : "mouse.exited.global",
                                     "");
            return 0;
        case kMsgReloadConfig:
            if (g_state) {
                // Full teardown + re-run, no diffing (spec 5).
                g_state->scheduler.cancelAll();
                if (g_state->lua) g_state->lua->teardown();
                g_state->store.removeAll();
                g_state->settings = ybar::model::BarSettings{};
                g_state->bus.reset();
                if (g_state->komorebi) g_state->bus.addEvent("komorebi_workspace_change");
                if (g_state->ytile) {
                    g_state->bus.addEvent("ytile_workspace_change");
                    g_state->bus.addEvent("komorebi_workspace_change");
                }
                if (g_state->fonts) g_state->fonts->clear();
                g_state->hoverItemId = -1;
                g_state->appliedOffsetPhysical = -1;
                g_state->executeConfig();
                g_state->renderAll();
                g_state->hotload.noteReloadHappened();
            }
            return 0;
        case WM_POWERBROADCAST:
            if (g_state) {
                if (wParam == PBT_APMSUSPEND) g_state->bus.trigger("system_will_sleep", "");
                else if (wParam == PBT_APMRESUMEAUTOMATIC)
                    g_state->bus.trigger("system_woke", "");
                else
                    g_state->publishPower(false);
            }
            return TRUE;
        case WM_DISPLAYCHANGE:
            // Debounced: a monitor hot-plug or resolution change emits a
            // burst, and rebuilding per message would thrash the GPU stack.
            if (g_state) SetTimer(hwnd, kDisplayChangeTimer, 500, nullptr);
            return 0;
        case WM_DPICHANGED:
            // The surface already resized itself; the daemon only needs to
            // re-render through the atlas for the new scale.
            if (g_state) {
                g_state->bus.trigger("display_change",
                                     std::to_string(ybar::win::enumerateMonitors().size()));
                g_state->renderAll();
            }
            return 0;
        case WM_FONTCHANGE:
            // Broadcasts reach the BAR windows, not this message-only window
            // (spec 7.4) — but handle it here too in case of direct sends.
            if (g_state && g_state->fonts) g_state->fonts->clear();
            return 0;
        case WM_ENDSESSION:
            if (wParam) {
                // Same cleanup as --exit: never leave a reserved strip behind.
                if (g_state && g_state->komorebi) g_state->komorebi->clearWorkAreaOffset();
                if (g_state && g_state->ytile) g_state->ytile->clearWorkAreaOffset();
                PostQuitMessage(0);
            }
            return 0;
        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

void CALLBACK foregroundHook(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD) {
    if (g_state) g_state->publishFrontApp(false); // delivered on the UI thread
}

// Low-level mouse hook: a press OUTSIDE every ybar window closes auto-close
// popups (spec 3.9). Minimal work here — just a post to the mailbox.
LRESULT CALLBACK mouseHookProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code == HC_ACTION && g_state &&
        (wParam == WM_LBUTTONDOWN || wParam == WM_RBUTTONDOWN || wParam == WM_MBUTTONDOWN)) {
        const auto* info = reinterpret_cast<MSLLHOOKSTRUCT*>(lParam);
        const HWND target = WindowFromPoint(info->pt);
        const HWND root = target ? GetAncestor(target, GA_ROOT) : nullptr;
        bool inside = false;
        wchar_t className[32] = L"";
        if (root && GetClassNameW(root, className, 32)) {
            inside = wcscmp(className, L"ybar.bar") == 0 ||
                     wcscmp(className, L"ybar.popup") == 0;
        }
        if (!inside) PostMessageW(g_state->messageWindow, kMsgCloseAutoPopups, 0, 0);
    }
    // mouse.entered.global / mouse.exited.global: the pointer crossing into
    // or out of the union of every ybar window. Only tracked once something
    // subscribes — WindowFromPoint on every move is not free.
    if (code == HC_ACTION && g_state && g_state->globalMouseArmed && wParam == WM_MOUSEMOVE) {
        const auto* info = reinterpret_cast<MSLLHOOKSTRUCT*>(lParam);
        const bool inside = ybar::win::pointOverYBarWindow(info->pt.x, info->pt.y);
        // A slider drag vetoes the exit (spec 6): the pointer routinely leaves
        // every window mid-drag, and a global exit there would let scripts
        // close the popup out from under the drag and eat the release. The
        // release re-checks containment.
        const bool vetoed = !inside && g_state->draggingSliderId != -1;
        if (inside != g_state->globalMouseInside && !vetoed) {
            g_state->globalMouseInside = inside;
            PostMessageW(g_state->messageWindow, kMsgGlobalMouse, inside ? 1 : 0, 0);
        }
    }
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

// modifier_change (spec 3.4): armed only when subscribed. This reads modifier
// key STATE on any key transition — it never inspects which key was pressed.
LRESULT CALLBACK keyboardHookProc(int code, WPARAM wParam, LPARAM lParam) {
    if (code == HC_ACTION && g_state) {
        const auto* info = reinterpret_cast<KBDLLHOOKSTRUCT*>(lParam);
        switch (info->vkCode) {
            case VK_LSHIFT: case VK_RSHIFT: case VK_SHIFT:
            case VK_LCONTROL: case VK_RCONTROL: case VK_CONTROL:
            case VK_LMENU: case VK_RMENU: case VK_MENU:
            case VK_LWIN: case VK_RWIN:
                PostMessageW(g_state->messageWindow, kMsgModifier, 0, 0);
                break;
            default:
                break;
        }
    }
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

} // namespace

void DaemonState::executeConfig() {
    resolvedConfigPath = locateConfig(instance, explicitConfigPath);
    if (resolvedConfigPath.empty()) return;
    const auto slash = resolvedConfigPath.find_last_of("\\/");
    const std::string directory =
        slash == std::string::npos ? "." : resolvedConfigPath.substr(0, slash);
    scripts.baseEnvironment = {{"CONFIG_DIR", directory}, {"BAR_NAME", instance}};
    scripts.workingDirectory = directory;
    trace("config: executing");

    const auto dot = resolvedConfigPath.find_last_of('.');
    const std::string extension =
        dot == std::string::npos ? "" : resolvedConfigPath.substr(dot);
    if (extension == ".json" || extension == ".jsonc") {
        std::string text;
        if (FILE* file = std::fopen(resolvedConfigPath.c_str(), "rb")) {
            char buffer[4096];
            std::size_t n;
            while ((n = std::fread(buffer, 1, sizeof(buffer), file)) > 0)
                text.append(buffer, n);
            std::fclose(file);
        }
        const auto filename =
            slash == std::string::npos ? resolvedConfigPath : resolvedConfigPath.substr(slash + 1);
        for (const auto& batch : translateJsonc(text, filename)) {
            const auto output = handler->handle(batch);
            if (!output.empty()) std::fprintf(stderr, "%s\n", output.c_str());
        }
    } else if (extension == ".lua") {
        if (lua) lua->runConfig(resolvedConfigPath);
    } else {
        scripts.runFile(resolvedConfigPath, {}); // config drives the bar via the CLI
    }
}

// The WM_DISPLAYCHANGE sledgehammer (spec 6): tear every surface down and
// build the set again from the current monitor list. Debounced by the caller.
void DaemonState::rebuildSurfaces() {
    if (!renderer) return;
    surfaces.clear();
    // Atlases are per-scale and a display change can retire a scale entirely.
    atlases.clear();
    // A destroyed window never delivers WM_MOUSELEAVE, so the pointer would
    // stay "inside" forever and mouse.exited.global would die for the session.
    if (globalMouseInside) {
        globalMouseInside = false;
        bus.trigger("mouse.exited.global", "");
    }
    hoverItemId = -1;
    for (const auto& monitor : ybar::win::enumerateMonitors()) {
        if (!settings.includesDisplay(monitor.arrangementIndex, monitor.primary)) continue;
        auto surface = ybar::win::BarSurface::create(*renderer, monitor, settings);
        if (!surface) continue;
        surfaces.push_back(std::move(surface));
    }
    surfaceFrames.assign(surfaces.size(), {});
    attachMouseHandlers();
    appliedOffsetPhysical = -1; // force the work-area handshake to re-run
    renderAll();
}

// Subscribes to komorebi when it is running and we are not already attached.
// Re-tried from the 1 s tick, so starting komorebi after ybar attaches on its
// own instead of needing a daemon restart (spec 11.3).
bool DaemonState::tryAttachKomorebi() {
    if (komorebi || ytile) return false;
    if (settings.reserve == ybar::model::ReserveMode::Off ||
        settings.reserve == ybar::model::ReserveMode::AppBar)
        return false;
    if (!ybar::providers::KomorebiProvider::detect()) return false;

    komorebi = std::make_unique<ybar::providers::KomorebiProvider>();
    komorebi->onUpdate = [hwnd = messageWindow](const ybar::providers::KomorebiUpdate& update) {
        auto* copy = new ybar::providers::KomorebiUpdate(update);
        if (!PostMessageW(hwnd, kMsgKomorebi, 0, reinterpret_cast<LPARAM>(copy))) delete copy;
    };
    komorebi->onAppEvent = [hwnd = messageWindow](const std::string& event,
                                                  const std::string& exe) {
        auto* payload = new std::pair<std::string, std::string>(event, exe);
        if (!PostMessageW(hwnd, kMsgKomorebiApp, 0, reinterpret_cast<LPARAM>(payload)))
            delete payload;
    };
    bus.addEvent("komorebi_workspace_change");
    if (!komorebi->start("ybar.sock")) {
        std::fprintf(stderr, "[ybar] komorebi subscription failed\n");
        komorebi.reset();
        return false;
    }
    trace("komorebi: subscribed");
    appliedOffsetPhysical = -1; // re-run the work-area handshake
    renderAll();
    return true;
}

void DaemonState::updateFullscreenElevation() {
    for (const auto& surface : surfaces) {
        surface->setFullscreenElevation(settings.fullscreenShow &&
                                        surface->monitorHasFullscreenWindow());
    }
}

// Provider arming (spec 10). Each callback runs on an OS notification thread,
// so every one of them does nothing but post to the UI thread's mailbox.
void DaemonState::armAudio() {
    if (audio) return;
    audio = std::make_unique<ybar::providers::AudioProvider>();
    audio->onVolume = [hwnd = messageWindow](int percent) {
        PostMessageW(hwnd, kMsgVolume, static_cast<WPARAM>(percent), 0);
    };
    if (!audio->start()) {
        std::fprintf(stderr, "[ybar] audio provider unavailable\n");
        audio.reset();
    }
}

void DaemonState::armMedia() {
    if (media) return;
    media = std::make_unique<ybar::providers::MediaProvider>();
    media->onChange = [hwnd = messageWindow](
                          const ybar::providers::MediaEnvironment& environment) {
        auto* copy = new ybar::providers::MediaEnvironment(environment);
        if (!PostMessageW(hwnd, kMsgMedia, 0, reinterpret_cast<LPARAM>(copy))) delete copy;
    };
    if (!media->start()) media.reset();
}

void DaemonState::armNetwork() {
    if (network) return;
    network = std::make_unique<ybar::providers::NetworkProvider>();
    network->onChange = [hwnd = messageWindow](const std::string& info) {
        auto* copy = new std::string(info);
        if (!PostMessageW(hwnd, kMsgNetwork, 0, reinterpret_cast<LPARAM>(copy))) delete copy;
    };
    if (!network->start()) {
        std::fprintf(stderr, "[ybar] network provider unavailable\n");
        network.reset();
    }
}

void DaemonState::publishPower(bool forced) {
    SYSTEM_POWER_STATUS status{};
    if (!GetSystemPowerStatus(&status)) return;
    // ACLineStatus: 0 battery, 1 AC, 255 unknown; PoHot maps to AC (spec 10).
    const std::string source = status.ACLineStatus == 0 ? "BATTERY" : "AC";
    if (forced || source != lastPowerSource) {
        lastPowerSource = source;
        bus.trigger("power_source_change", source);
    }
    if (status.BatteryLifePercent != 255) {
        const int percent = status.BatteryLifePercent;
        if (forced || percent != lastBatteryPercent) {
            lastBatteryPercent = percent;
            bus.trigger("battery_change", std::to_string(percent));
        }
    }
}

void DaemonState::publishFrontApp(bool forced) {
    // FileDescription, with the UWP frame-host unwrap (spec 10) — the plain
    // exe basename reports "ApplicationFrameHost" for every packaged app.
    const std::string name = ybar::providers::appNameForWindow(GetForegroundWindow());
    // A foreground change is exactly when a window can become (or stop being)
    // fullscreen — the reference re-evaluates on the same signal.
    updateFullscreenElevation();
    if (name.empty()) return;
    if (!forced && name == lastFrontApp) return;
    lastFrontApp = name;
    bus.trigger("front_app_switched", name);
}

void DaemonState::sampleStats() {
    FILETIME idleFt, kernelFt, userFt;
    if (!GetSystemTimes(&idleFt, &kernelFt, &userFt)) return;
    const auto toU64 = [](const FILETIME& ft) {
        return (static_cast<ULONGLONG>(ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    };
    const ULONGLONG idle = toU64(idleFt), kernel = toU64(kernelFt), user = toU64(userFt);
    int cpuPercent = 0;
    if (statsPrevKernel != 0) {
        const ULONGLONG idleDelta = idle - statsPrevIdle;
        // Kernel time INCLUDES idle: busy = (kernel - idle) + user (spec 10).
        const ULONGLONG busy = (kernel - statsPrevKernel) - idleDelta + (user - statsPrevUser);
        const ULONGLONG total = (kernel - statsPrevKernel) + (user - statsPrevUser);
        if (total > 0)
            cpuPercent = static_cast<int>((busy * 100 + total / 2) / total);
    }
    statsPrevIdle = idle;
    statsPrevKernel = kernel;
    statsPrevUser = user;

    MEMORYSTATUSEX memory{};
    memory.dwLength = sizeof(memory);
    GlobalMemoryStatusEx(&memory);
    const int memoryPercent = static_cast<int>(
        (memory.ullTotalPhys - memory.ullAvailPhys) * 100 / memory.ullTotalPhys);

    ULARGE_INTEGER freeBytes{}, totalBytes{};
    const char* profile = std::getenv("USERPROFILE");
    GetDiskFreeSpaceExA(profile ? profile : "C:\\", &freeBytes, &totalBytes, nullptr);

    char cpuFraction[16], memoryFraction[16];
    std::snprintf(cpuFraction, sizeof(cpuFraction), "%.2f", cpuPercent / 100.0);
    std::snprintf(memoryFraction, sizeof(memoryFraction), "%.2f", memoryPercent / 100.0);
    // INFO shape is exact contract: space after the colon (spec 3.5).
    const std::string info = "{\"cpu\": " + std::to_string(cpuPercent) +
                             ", \"memory\": " + std::to_string(memoryPercent) + "}";
    bus.trigger("system_stats", info,
                {{"CPU_USAGE", std::to_string(cpuPercent)},
                 {"CPU_FRACTION", cpuFraction},
                 {"MEMORY_USAGE", std::to_string(memoryPercent)},
                 {"MEMORY_FRACTION", memoryFraction},
                 {"DISK_FREE_GB",
                  std::to_string(freeBytes.QuadPart / 1000000000ull)},
                 {"DISK_TOTAL_GB",
                  std::to_string(totalBytes.QuadPart / 1000000000ull)},
                 {"THERMAL_STATE", "nominal"}});
}

void DaemonState::dispatchClick(ybar::model::Item& item, const char* button,
                                const char* modifier) {
    const std::string info = std::string("{\"button\":\"") + button + "\",\"modifier\":\"" +
                             modifier + "\"}";
    ybar::events::Environment extra{{"BUTTON", button}, {"MODIFIER", modifier}};
    // click_script runs FIRST, then the event (reference ordering).
    if (!item.clickScript.empty()) {
        auto scriptEnv = extra;
        scriptEnv["NAME"] = item.name;
        scriptEnv["INFO"] = info;
        scripts.run(item.clickScript, scriptEnv);
    }
    bus.triggerTargeted(item, "mouse.clicked", info, extra);
}

// Maps a bar-local x to a slider percentage. The track starts after the
// item's left padding, the alignment slack of a fixed-width item, and the
// icon — the same offsets the renderer uses.
void DaemonState::updateSlider(ybar::model::Item& item, std::size_t surfaceIndex,
                               double localX) {
    if (!item.slider || !fonts) return;
    const auto* frame = frameFor(surfaceIndex, item.id);
    if (!frame) return;

    double trackX = frame->x + item.paddingLeft;
    if (item.customWidth >= 0) {
        const double slack =
            std::max(0.0, item.customWidth - ybar::model::naturalLength(item, measureItem(item)));
        if (item.align == 'c') trackX += slack / 2;
        else if (item.align == 'r') trackX += slack;
    }
    if (item.icon.drawing && !item.icon.displayString().empty()) {
        const auto& icon = fonts->shape(item.icon.displayString(), item.icon.font);
        trackX += item.icon.paddingLeft + icon.width + item.icon.paddingRight;
    }
    const double width = item.slider->width > 0 ? item.slider->width : 1;
    item.slider->percentage =
        std::min(100.0, std::max(0.0, (localX - trackX) / width * 100.0));
    if (renderer && !renderQueued) {
        renderQueued = true; // coalesce to one frame per turn (spec 7.2)
        PostMessageW(messageWindow, kMsgRender, 0, 0);
    }
}

void DaemonState::closeAutoClosePopups(int exceptHostId) {
    bool changed = false;
    for (const auto& item : store.items()) {
        if (!item->popup.isOpen || !item->popup.autoClose) continue;
        if (item->id == exceptHostId) continue;
        item->popup.isOpen = false;
        changed = true;
    }
    if (changed) renderAll();
}

void DaemonState::showTooltip(ybar::model::Item& item) {
    if (!renderer || !fonts || surfaces.empty()) return;
    auto& surface = *surfaces.front();
    const double scale = surface.scale();
    auto* atlas = atlasFor(scale);
    if (!atlas) return;

    // Tooltip constants are visual contract (spec 3.9).
    ybar::model::TextPart text;
    text.string = item.tooltip;
    text.color = ybar::model::Color{0xffffffff};
    text.font.size = 11;
    const auto& line = fonts->shape(text.displayString(), text.font);
    const ybar::model::Size panel{line.width + 20, std::max(line.measuredHeight() + 10, 24.0)};

    ybar::render::DisplayList list;
    list.viewportSize = {static_cast<float>(std::round(panel.width * scale)),
                         static_cast<float>(std::round(panel.height * scale))};
    ybar::model::Item bubble; // transient: background plate + centered text
    bubble.background.drawing = true;
    bubble.background.color = ybar::model::Color{0xf2202024};
    bubble.background.cornerRadius = 6;
    bubble.background.height = panel.height;
    bubble.icon.drawing = false;
    bubble.label = text;
    bubble.label.paddingLeft = 10;
    ybar::render::emitItem(list, bubble, ybar::model::Rect{0, 0, panel.width, panel.height},
                           scale, *fonts, *atlas);

    if (!tooltip) tooltip = ybar::win::PopupSurface::create(*renderer, scale);
    if (!tooltip) return;
    const auto origin = surface.screenOrigin();
    const ybar::model::Rect anchor{origin.x + item.frame.x * scale,
                                   origin.y + item.frame.y * scale, item.frame.width * scale,
                                   item.frame.height * scale};
    tooltip->present(panel, anchor, 'c', settings.position == ybar::model::BarPosition::Top, 4);
    renderer->render(list, tooltip->renderSurface(), atlas);
}

void DaemonState::hideTooltip() {
    if (tooltip) tooltip->hide();
    KillTimer(messageWindow, kTooltipTimer);
}

void DaemonState::updatePopups() {
    if (!renderer || !fonts || surfaces.empty()) return;
    auto& hostSurface = *surfaces.front(); // popups render at the primary bar's scale
    const double scale = hostSurface.scale();
    auto* atlas = atlasFor(scale);
    if (!atlas) return;
    const auto measure = [this](const ybar::model::Item& item) { return measureItem(item); };

    // Orphan cleanup: hosts removed since the last frame (e.g. --reload).
    for (auto it = popups.begin(); it != popups.end();) {
        bool hostExists = false;
        for (const auto& item : store.items()) {
            if (item->id == it->first) {
                hostExists = true;
                break;
            }
        }
        if (!hostExists) {
            it->second.surface->hide();
            it = popups.erase(it);
        } else {
            ++it;
        }
    }

    for (const auto& host : store.items()) {
        const bool wantsOpen = host->popup.isOpen && !host->frame.isZero();
        auto liveIt = popups.find(host->id);
        if (!wantsOpen) {
            if (liveIt != popups.end()) {
                liveIt->second.surface->hide();
                popups.erase(liveIt);
            }
            continue;
        }

        std::vector<ybar::model::Item*> members;
        for (const auto& member : store.items()) {
            if (member->position == ybar::model::ItemPosition::Popup &&
                member->popupHost == host->name && member->drawing)
                members.push_back(member.get());
        }
        if (members.empty()) {
            if (liveIt != popups.end()) {
                liveIt->second.surface->hide();
                popups.erase(liveIt);
            }
            continue;
        }

        const auto layout = ybar::model::layoutPopup(members, host->popup, measure);
        auto scene = ybar::render::buildPopupScene(members, layout.contentBoxes, host->popup,
                                                   layout.panelSize, scale, *fonts, *atlas);
        if (scene.empty()) { // never leave a stale, still-clickable panel
            if (liveIt != popups.end()) {
                liveIt->second.surface->hide();
                popups.erase(liveIt);
            }
            continue;
        }

        if (liveIt == popups.end()) {
            auto surface = ybar::win::PopupSurface::create(*renderer, scale);
            if (!surface) continue;
            liveIt = popups.emplace(host->id, LivePopup{std::move(surface), {}, {}}).first;
            liveIt->second.surface->setMouseHandler(
                [this, hostId = host->id](const ybar::win::MouseEvent& event) {
                    if (event.kind != ybar::win::MouseEvent::Kind::Up) return;
                    const auto it = popups.find(hostId);
                    if (it == popups.end()) return;
                    for (std::size_t i = 0; i < it->second.boxes.size(); ++i) {
                        if (!it->second.boxes[i].contains({event.x, event.y})) continue;
                        for (const auto& item : store.items()) {
                            if (item->id == it->second.memberIds[i]) {
                                dispatchClick(*item, event.button, event.modifier);
                                break;
                            }
                        }
                        break; // press inside a popup never dismisses it (spec 3.9)
                    }
                });
        }
        auto& live = liveIt->second;
        live.memberIds.clear();
        for (auto* member : members) live.memberIds.push_back(member->id);
        live.boxes = layout.contentBoxes;

        const auto origin = hostSurface.screenOrigin();
        const ybar::model::Rect anchor{origin.x + host->frame.x * scale,
                                       origin.y + host->frame.y * scale,
                                       host->frame.width * scale, host->frame.height * scale};
        live.surface->setBackdrop(host->popup.blurRadius > 0,
                                  host->popup.background.cornerRadius);
        live.surface->present(layout.panelSize, anchor, host->popup.align,
                              settings.position == ybar::model::BarPosition::Top,
                              host->popup.yOffset);
        // A panel counts as live only once its scene actually rendered.
        if (!renderer->render(scene, live.surface->renderSurface(), atlas)) {
            live.surface->hide();
            popups.erase(liveIt);
            SetTimer(messageWindow, kRenderRetryTimer, 1000, nullptr);
        }
    }
}

void DaemonState::renderAll() {
    if (!renderer || !fonts) return;
    trace("renderAll: begin");
    marqueeOnScreen = false; // recomputed from this frame's scenes
    surfaceFrames.resize(surfaces.size());
    for (std::size_t surfaceIndex = 0; surfaceIndex < surfaces.size(); ++surfaceIndex) {
        auto& surface = surfaces[surfaceIndex];
        trace("renderAll: applySettings");
        surface->applySettings(settings);
        if (settings.hidden) continue;
        const double scale = surface->scale();
        trace("renderAll: atlas");
        auto* atlas = atlasFor(scale);
        if (!atlas) continue;

        const ybar::model::LayoutSettings layoutSettings{
            surface->logicalWidth(), surface->logicalHeight(), settings.paddingLeft,
            settings.paddingRight, 0 /* no notch on Windows */};
        const auto measure = [&](const ybar::model::Item& item) {
            ybar::model::MeasuredContent m;
            const auto& icon = fonts->shape(item.icon.displayString(), item.icon.font);
            const auto& label = fonts->shape(item.label.displayString(), item.label.font);
            m.icon = {icon.width, icon.measuredHeight()};
            m.label = {label.width, label.measuredHeight()};
            return m;
        };
        trace("renderAll: layout");
        auto boxes = ybar::model::layout(store.items(), layoutSettings, measure);

        // Bracket frames are derived post-layout from member content boxes
        // (spec 3.9) — they drive both rendering and hit testing.
        for (const auto& item : store.items()) {
            if (item->kind != ybar::model::ItemKind::Bracket) continue;
            item->frame = ybar::model::bracketFrame(*item, store.expandMembers(item->members),
                                                    boxes, surface->logicalHeight());
        }

        // Snapshot this surface's geometry before the next one overwrites
        // item->frame (layout writes it in place).
        auto& frames = surfaceFrames[surfaceIndex];
        frames.clear();
        for (const auto& item : store.items())
            if (!item->frame.isZero()) frames[item->id] = item->frame;

        ybar::render::SceneParams params{surface->logicalWidth(), surface->logicalHeight(),
                                         scale, monotonicSeconds()};
        trace("renderAll: buildScene");
        const auto list =
            ybar::render::buildScene(store.items(), boxes, settings, params, *fonts, *atlas);
        trace("renderAll: render");
        if (list.hasMarquee) marqueeOnScreen = true; // keeps the clock running
        if (!renderer->render(list, surface->renderSurface(), atlas)) {
            SetTimer(messageWindow, kRenderRetryTimer, 1000, nullptr); // spec 7.2
        }
        trace("renderAll: surface done");
    }

    updatePopups();

    // Work-area handshake follows bar-height changes (spec 11.4).
    if ((komorebi || ytile) && !surfaces.empty()) {
        const double scale = surfaces.front()->scale();
        const int physical = settings.hidden
                                 ? 0
                                 : static_cast<int>((settings.height + settings.yOffset) * scale + 0.5);
        if (physical != appliedOffsetPhysical) {
            appliedOffsetPhysical = physical;
            if (komorebi) komorebi->applyWorkAreaOffset(physical);
            if (ytile) ytile->applyWorkAreaOffset(physical);
        }
    }
}

int runDaemon(const std::string& instance, const std::string& configPath) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    // Taskbar / notification identity (spec 13), successor to com.ybar.YBar.
    SetCurrentProcessExplicitAppUserModelID(L"YBar.YBar");
    // COM must be live before the first surface is built: sticky pinning
    // CoCreateInstances the virtual desktop manager during window setup, and
    // without this it failed at boot with "no virtual desktop manager".
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);

    DaemonState state;
    state.instance = instance;
    state.explicitConfigPath = configPath;
    g_state = &state;

    WNDCLASSW windowClass{};
    windowClass.lpfnWndProc = messageWindowProc;
    windowClass.hInstance = GetModuleHandleW(nullptr);
    windowClass.lpszClassName = L"ybar.message";
    RegisterClassW(&windowClass);
    state.messageWindow = CreateWindowExW(0, windowClass.lpszClassName, L"", 0, 0, 0, 0, 0,
                                          HWND_MESSAGE, nullptr, windowClass.hInstance, nullptr);
    if (!state.messageWindow) {
        std::fprintf(stderr, "[!] ybar failed to start: message window\n");
        return 1;
    }

    // Instance lock FIRST (spec 5): a second launch must fail before it can
    // create windows or touch shared provider state — otherwise it deletes
    // and re-registers the live instance's komorebi subscriber socket.
    ybar::ipc::SocketServer server;
    const auto socketPath = ybar::ipc::socketPath(instance);
    if (const auto error = server.reserve(socketPath)) {
        std::fprintf(stderr, "%s\n", error->c_str());
        return 1;
    }
    trace("instance lock: acquired");

    // GPU stack — graceful degradation to headless when unavailable.
    trace("renderer: create");
    state.renderer = ybar::render::Renderer::create(exeDirectory() + "\\shaders\\ybar.hlsl");
    trace("renderer: created");
    if (state.renderer) {
        state.fonts = ybar::render::FontCache::create();
        trace("fonts: created");
        for (const auto& monitor : ybar::win::enumerateMonitors()) {
            if (!state.settings.includesDisplay(monitor.arrangementIndex, monitor.primary))
                continue;
            trace("surface: create");
            auto surface = ybar::win::BarSurface::create(*state.renderer, monitor,
                                                         state.settings);
            trace("surface: created");
            if (surface) state.surfaces.push_back(std::move(surface));
        }
    } else {
        std::fprintf(stderr, "[ybar] rendering unavailable — running headless\n");
    }
    trace("gpu stack ready");

    // Scripts: Lua-first dispatch, shell fallback (spec 3.7, 10.1).
    state.bus.itemsProvider = [&state] {
        std::vector<ybar::model::Item*> items;
        for (const auto& item : state.store.items()) items.push_back(item.get());
        return items;
    };
    state.bus.runItemScript = [&state](ybar::model::Item& item,
                                       const ybar::events::Environment& env) {
        if (state.lua && state.lua->handleEvent(item, env)) return;
        if (!item.script.empty()) state.scripts.run(item.script, env);
    };

    // Mouse routing: hit-test bar-local item frames, targeted dispatch
    // bypassing the updates policy (spec 3.4, 6).
    {
        state.mouseHandler = [&state](std::size_t surfaceIndex,
                                      const ybar::win::MouseEvent& event) {
            // Two-pass hit test (spec 3.9): non-bracket members win; a
            // bracket is hit only where no member covers the point. Frames
            // come from the surface the event arrived on — item->frame holds
            // whichever monitor rendered last.
            auto hitTest = [&state, surfaceIndex](double x, double y) -> ybar::model::Item* {
                const auto& items = state.store.items();
                ybar::model::Item* bracket = nullptr;
                for (auto it = items.rbegin(); it != items.rend(); ++it) {
                    auto* item = it->get();
                    if (item->position == ybar::model::ItemPosition::Popup) continue;
                    const auto* frame = state.frameFor(surfaceIndex, item->id);
                    if (!frame || !frame->contains({x, y})) continue;
                    if (item->kind == ybar::model::ItemKind::Bracket) {
                        if (!bracket) bracket = item;
                        continue;
                    }
                    return item;
                }
                return bracket;
            };
            using Kind = ybar::win::MouseEvent::Kind;

            // A slider drag captures the pointer: motion past the item's own
            // frame keeps updating it, and the release commits the value.
            if (state.draggingSliderId != -1 &&
                (event.kind == Kind::Move || event.kind == Kind::Up)) {
                for (const auto& candidate : state.store.items()) {
                    if (candidate->id != state.draggingSliderId || !candidate->slider) continue;
                    const bool released = event.kind == Kind::Up;
                    candidate->slider->isDragged = !released;
                    state.updateSlider(*candidate, surfaceIndex, event.x);
                    if (released) {
                        state.draggingSliderId = -1;
                        const int percentage =
                            static_cast<int>(std::lround(candidate->slider->percentage));
                        ybar::events::Environment extra{{"PERCENTAGE",
                                                         std::to_string(percentage)},
                                                        {"BUTTON", "left"},
                                                        {"MODIFIER", "none"}};
                        if (!candidate->clickScript.empty()) {
                            auto scriptEnv = extra;
                            scriptEnv["NAME"] = candidate->name;
                            state.scripts.run(candidate->clickScript, scriptEnv);
                        }
                        state.bus.triggerTargeted(*candidate, "mouse.clicked", "", extra);
                        // The drag vetoed any global exit; settle it now.
                        if (state.globalMouseArmed) {
                            POINT cursor{};
                            GetCursorPos(&cursor);
                            const bool inside =
                                ybar::win::pointOverYBarWindow(cursor.x, cursor.y);
                            if (inside != state.globalMouseInside) {
                                state.globalMouseInside = inside;
                                state.bus.trigger(inside ? "mouse.entered.global"
                                                         : "mouse.exited.global",
                                                  "");
                            }
                        }
                    }
                    break;
                }
                return;
            }

            auto* item = event.kind == Kind::Leave ? nullptr : hitTest(event.x, event.y);

            // Hover transitions (mouse.entered / mouse.exited) + tooltip dwell.
            const int hoverId = item ? item->id : -1;
            if (hoverId != state.hoverItemId) {
                state.hideTooltip();
                if (state.hoverItemId != -1) {
                    for (const auto& candidate : state.store.items()) {
                        if (candidate->id != state.hoverItemId) continue;
                        candidate->mouseOver = false;
                        state.bus.triggerTargeted(*candidate, "mouse.exited", "");
                        break;
                    }
                }
                if (item) {
                    item->mouseOver = true;
                    state.bus.triggerTargeted(*item, "mouse.entered", "");
                    if (!item->tooltip.empty()) {
                        state.tooltipItemId = item->id;
                        SetTimer(state.messageWindow, kTooltipTimer, 600, nullptr);
                    }
                }
                state.hoverItemId = hoverId;
            }

            // A press ANYWHERE on the bar — including empty space — closes
            // auto-close popups except the pressed host's (spec 3.9).
            if (event.kind == Kind::Down) {
                state.closeAutoClosePopups(item ? item->id : -1);
                if (item && item->slider) {
                    state.draggingSliderId = item->id;
                    item->slider->isDragged = true;
                    // An in-flight percentage animation would fight the drag
                    // every frame (spec 3.9).
                    state.scheduler.cancel("item." + std::to_string(item->id) +
                                           ".slider.percentage");
                    state.updateSlider(*item, surfaceIndex, event.x);
                }
                return;
            }
            if (!item) return;

            if (event.kind == Kind::Up) { // clicks fire on mouse-UP (spec 3.5)
                state.dispatchClick(*item, event.button, event.modifier);
            } else if (event.kind == Kind::Scroll) {
                state.bus.triggerTargeted(*item, "mouse.scrolled", "",
                                          {{"SCROLL_DELTA", std::to_string(event.scrollDelta)},
                                           {"MODIFIER", event.modifier}});
            }
        };
        state.attachMouseHandlers();
    }

    // YTile: the sibling WM adapter — preferred when its pipe is present
    // (the user runs one WM at a time; ytiled's presence is the signal).
    if (state.settings.reserve != ybar::model::ReserveMode::Off &&
        state.settings.reserve != ybar::model::ReserveMode::AppBar &&
        ybar::providers::YTileProvider::detect()) {
        state.ytile = std::make_unique<ybar::providers::YTileProvider>();
        state.ytile->onUpdate = [hwnd = state.messageWindow](
                                    const ybar::providers::YTileUpdate& update) {
            auto* copy = new ybar::providers::YTileUpdate(update);
            if (!PostMessageW(hwnd, kMsgYTile, 0, reinterpret_cast<LPARAM>(copy)))
                delete copy;
        };
        state.bus.addEvent("ytile_workspace_change");
        state.bus.addEvent("komorebi_workspace_change"); // config compatibility
        if (!state.ytile->start()) {
            std::fprintf(stderr, "[ybar] ytile subscription failed\n");
            state.ytile.reset();
        } else {
            trace("ytile: subscribed");
        }
    }

    // komorebi (spec 11): subscription + work-area handshake, gated by reserve.
    state.tryAttachKomorebi();

    // System providers (spec 10): power push notifications + front-app hook
    // always on; stats armed lazily on first subscription.
    RegisterPowerSettingNotification(state.messageWindow, &kGuidAcDcPowerSource,
                                     DEVICE_NOTIFY_WINDOW_HANDLE);
    RegisterPowerSettingNotification(state.messageWindow, &kGuidBatteryPercentage,
                                     DEVICE_NOTIFY_WINDOW_HANDLE);
    const HWINEVENTHOOK frontAppHook =
        SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
                        foregroundHook, 0, 0, WINEVENT_OUTOFCONTEXT);
    state.mouseHook = SetWindowsHookExW(WH_MOUSE_LL, mouseHookProc,
                                        GetModuleHandleW(nullptr), 0);
    state.bus.onFirstSubscription = [&state](const std::string& event) {
        if (event == "system_stats" && !state.statsArmed) {
            state.statsArmed = true;
            state.sampleStats(); // prime the tick deltas
            SetTimer(state.messageWindow, kStatsTimer, 2000, nullptr);
        } else if (event == "volume_change") {
            state.armAudio();
        } else if (event == "wifi_change") {
            state.armNetwork();
        } else if (event == "media_change") {
            state.armMedia();
        } else if (event == "app_launched" || event == "app_terminated") {
            // komorebi already feeds these from Show/Destroy; the poller is
            // only for the WM-less case (spec 10).
            if (!state.komorebi && !state.appLifecycleArmed) {
                state.appLifecycleArmed = true;
                state.appLifecycle.prime(); // never announce the existing world
                SetTimer(state.messageWindow, kAppsTimer, 2000, nullptr);
            }
        } else if (event == "modifier_change") {
            if (!state.keyboardHook) {
                state.keyboardHook = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardHookProc,
                                                       GetModuleHandleW(nullptr), 0);
            }
        } else if (event == "mouse.entered.global" || event == "mouse.exited.global") {
            state.globalMouseArmed = true;
        }
    };
    state.appLifecycle.onEvent = [&state](const std::string& event, const std::string& name) {
        state.bus.trigger(event, name); // already on the UI thread (timer)
    };
    ybar::win::BarSurface::setBroadcastTarget(state.messageWindow);
    state.hotload.onChange = [hwnd = state.messageWindow] {
        PostMessageW(hwnd, kMsgReloadConfig, 0, 0);
    };

    ybar::ipc::DaemonHooks hooks;
    hooks.exit = [hwnd = state.messageWindow] { SetTimer(hwnd, kExitTimer, 150, nullptr); };
    hooks.requestSsidPermission = [] {
        ybar::providers::NetworkProvider::openLocationPrivacySettings();
    };
    hooks.komorebiMessage = [](const std::string& jsonText) {
        return ybar::providers::KomorebiProvider::detect() &&
               ybar::providers::KomorebiProvider::sendMessage(jsonText);
    };
    hooks.reload = [&state](const std::string& explicitPath) {
        // --reload [path] re-points the config before the teardown re-run.
        if (!explicitPath.empty()) state.explicitConfigPath = explicitPath;
        PostMessageW(state.messageWindow, kMsgReloadConfig, 0, 0);
    };
    hooks.setHotload = [&state](bool enabled) {
        state.hotload.setEnabled(enabled, state.resolvedConfigPath);
    };
    hooks.forcedUpdate = [&state] {
        state.publishPower(true);
        state.publishFrontApp(true);
        // Only already-armed providers re-publish here, matching the
        // reference: --update never arms a provider nothing subscribed to.
        if (state.audio) state.audio->refresh();
        if (state.network) state.network->refresh();
        if (state.statsArmed) state.sampleStats();
    };
    hooks.forcedQuery = [&state](const std::string& event) {
        // The --trigger interception set (spec 3.4). Unlike --update, an
        // explicit trigger arms the provider first.
        if (event == "volume_change") {
            state.armAudio();
            return state.audio && state.audio->refresh();
        }
        if (event == "wifi_change") {
            state.armNetwork();
            return state.network && state.network->refresh();
        }
        if (event == "media_change") {
            state.armMedia();
            return state.media && state.media->refresh();
        }
        if (event == "power_source_change" || event == "battery_change") {
            state.publishPower(true);
            return true;
        }
        if (event == "front_app_switched") {
            state.publishFrontApp(true);
            return true;
        }
        if (event == "system_stats") {
            state.sampleStats();
            return true;
        }
        if (event == "display_change") {
            state.bus.trigger("display_change",
                              std::to_string(ybar::win::enumerateMonitors().size()));
            return true;
        }
        // Workspace re-query: the boot-population idiom every workspaces
        // widget uses (spec 11.3) — replays FOCUSED_WORKSPACE from live state.
        if (event == "komorebi_workspace_change" || event == "ytile_workspace_change") {
            if (state.komorebi) return state.komorebi->refresh();
            if (state.ytile) return state.ytile->refresh();
            return false;
        }
        return false;
    };
    hooks.setNeedsRender = [&state] {
        if (state.renderQueued || !state.renderer) return;
        state.renderQueued = true; // coalesce to one frame per turn (spec 7.2)
        PostMessageW(state.messageWindow, kMsgRender, 0, 0);
    };
    hooks.measureNaturalWidth = [&state](const ybar::model::Item& item) {
        if (!state.fonts) return 0.0;
        return ybar::model::naturalLength(item, state.measureItem(item));
    };
    hooks.measureNaturalPartWidth = [&state](const ybar::model::Item& item, bool isIcon) {
        if (!state.fonts) return 0.0;
        const auto& part = isIcon ? item.icon : item.label;
        const auto& shaped = state.fonts->shape(part.displayString(), part.font);
        return shaped.width; // ink only; paddings are outside the part width
    };
    hooks.displays = [] { return ybar::win::displayInfos(); };
    hooks.boundingRects = [&state](const ybar::model::Item& item) {
        ybar::model::BoundingRects rects;
        for (std::size_t i = 0; i < state.surfaces.size(); ++i) {
            if (const auto* frame = state.frameFor(i, item.id))
                rects[state.surfaces[i]->monitor().arrangementIndex] = *frame;
        }
        return rects;
    };
    state.handler = std::make_unique<ybar::ipc::CommandHandler>(state.store, state.settings,
                                                                state.bus, hooks,
                                                                &state.scheduler);
    state.lua = std::make_unique<ybar::lua::LuaRuntime>(state.store, state.bus, *state.handler,
                                                        state.scripts, state.messageWindow);

    // The socket is already bound (instance lock); start serving it now that
    // the handler exists.
    server.serve([hwnd = state.messageWindow](const std::vector<std::string>& argv) {
        auto request = std::make_unique<IpcRequest>();
        request->argv = argv;
        auto future = request->reply.get_future();
        if (!PostMessageW(hwnd, kMsgIpcRequest, 0, reinterpret_cast<LPARAM>(request.get())))
            return std::string();
        request.release(); // UI thread owns it now and deletes after replying
        // Bounded wait (spec 5): a wedged UI thread must not wedge the serial
        // accept loop for every client.
        if (future.wait_for(std::chrono::seconds(2)) != std::future_status::ready)
            return std::string();
        return future.get();
    });

    SetTimer(state.messageWindow, kRoutineTimer, 1000, nullptr);
    state.executeConfig();
    if (state.renderer) state.renderAll(); // first frame

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (frontAppHook) UnhookWinEvent(frontAppHook);
    if (state.mouseHook) UnhookWindowsHookEx(static_cast<HHOOK>(state.mouseHook));
    if (state.keyboardHook) UnhookWindowsHookEx(static_cast<HHOOK>(state.keyboardHook));
    server.stop();
    DestroyWindow(state.messageWindow);
    g_state = nullptr;
    return 0;
}

} // namespace ybar::app
