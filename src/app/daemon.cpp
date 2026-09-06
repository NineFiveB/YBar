#include "app/daemon.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
#include <shobjidl.h> // SetCurrentProcessExplicitAppUserModelID
// clang-format on

#include <dcomp.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <future>
#include <memory>
#include <thread>
#include <unordered_map>
#include <utility>

#include <nlohmann/json.hpp>

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
#include "providers/audio_sessions.h"
#include "providers/komorebi.h"
#include "providers/media.h"
#include "providers/network.h"
#include "providers/tray_icons.h"
#include "providers/window_list.h"
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
#include "win/system_appearance.h"

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

// kMsgKomorebiApp payload: the hwnd lets the handler resolve the real
// process's FileDescription instead of trusting a bare exe basename.
struct KomorebiAppEvent {
    std::string event;
    std::string exe;
    std::uintptr_t hwnd = 0;
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
    // Surface-loss recovery (see recoverMissingSurfaces). The report is latched
    // and the retry backs off, so a permanently dead GPU stack costs one
    // rebuild a minute rather than one a second.
    bool surfaceLossReported = false;
    int surfaceRetryCountdown = 0; // ticks left before the next attempt
    int surfaceRetryDelay = 1;     // seconds, doubles to a cap while failing
    // Windows "Transparency effects": gates DWM Acrylic and forces popup panels
    // opaque when off. Cached and refreshed on WM_SETTINGCHANGE (spec 7.6).
    bool systemTransparency = ybar::win::systemTransparencyEnabled();

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
    HANDLE animationPumpStop = nullptr;
    // Auto-reset: the pump signals it each compositor tick and the message
    // loop consumes it AFTER draining pending messages — a posted frame
    // message would outrank hardware input in GetMessage and starve clicks
    // whenever render time approaches the frame budget.
    HANDLE frameDue = nullptr;
    std::thread animationPump;
    int appliedOffsetPhysical = -1;
    int hoverItemId = -1; // targeted mouse.entered/exited tracking
    // Pointer-tracked key light (glass pills only). Logical points on
    // `pointerSurface`; negative means the pointer is not over any bar.
    // `pointerLightActive` is recomputed each frame from the scene actually
    // built: with no glass quad on screen — which is every flat theme,
    // including the one that ships — the pointer path costs nothing at all
    // and the bar keeps its zero-work-at-rest behaviour.
    double pointerX = -1;
    double pointerY = -1;
    std::size_t pointerSurface = static_cast<std::size_t>(-1);
    double lastPointerRender = 0;
    bool pointerLightActive = false;

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
        // > 0 while a dismissed popup is fading out. The entry outlives the
        // dismissal by exactly the fade so the compositor has something to
        // animate; it stops hit-testing immediately, so the click that
        // dismissed it cannot land in a panel that is on its way out.
        double closingUntil = 0;
    };
    std::unordered_map<int, LivePopup> popups;
    std::unique_ptr<ybar::win::PopupSurface> tooltip;
    int tooltipItemId = -1;
    bool hotloadEnabled = false;  // mirrors the last --hotload state
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
    void recoverMissingSurfaces();
    bool tryAttachKomorebi();
    bool tryAttachYTile();
    void detachKomorebiIfReserveChanged();
    void updateFullscreenElevation();
    void armAudio();
    void armMedia();
    void armNetwork();
    void publishPower(bool forced);
    void publishPowerSource(bool forced);
    void publishBattery(bool forced);
    void publishFrontApp(bool forced);
    void sampleStats(bool publish = true);
    void updatePopups();
    void closeAutoClosePopups(int exceptHostId);
    void dispatchClick(ybar::model::Item& item, const char* button, const char* modifier);

    // Slider dragging (spec 3.9): the item captured on press keeps receiving
    // motion until release, even past its own frame. Shared by the bar and
    // popup mouse paths — only the frame source differs.
    int draggingSliderId = -1;
    double sliderContentOffset(const ybar::model::Item& item);
    void updateSlider(ybar::model::Item& item, std::size_t surfaceIndex, double localX);
    void updateSliderInPopup(ybar::model::Item& item, const LivePopup& live, double localX);
    void commitSliderRelease(ybar::model::Item& item);
    void showTooltip(ybar::model::Item& item);
    void hideTooltip();
    // Move targeted hover to `item` (nullptr = nothing hovered), firing
    // mouse.exited on the old and mouse.entered on the new. One
    // implementation for the bar and for popup rows, so a pointer crossing
    // between a pill and its open panel cannot leave two items lit.
    void setHoverItem(ybar::model::Item* item);
    // A popup torn down under the pointer sends no WM_MOUSELEAVE, so a row
    // left hovered would stay latched: its highlight would be stale on the
    // next open, and re-entering it would fire no `entered` because the id
    // never changed. Called from every popup teardown path.
    void releaseHoverIn(const LivePopup& popup);
    ybar::model::MeasuredContent measureItem(const ybar::model::Item& item) {
        ybar::model::MeasuredContent m;
        const auto& icon = fonts->shape(item.icon.displayString(), item.icon.font);
        const auto& label = fonts->shape(item.label.displayString(), item.label.font);
        m.icon = {icon.width, icon.measuredHeight()};
        m.label = {label.width, label.measuredHeight()};
        return m;
    }

    // On-demand frame clock: runs while animations exist OR a marquee is on
    // screen (continuousDemand, spec 7.2) — never otherwise. Frames are paced
    // by the compositor clock (DCompositionWaitForCompositorClock), which
    // ticks at the display's actual refresh rate — a WM_TIMER quantizes to
    // ~15.6 ms and caps animation at ~64 Hz on a 120 Hz panel. Everything
    // downstream is time-based (scheduler ticks and the marquee offset take
    // monotonic seconds), so the clock source changes smoothness only.
    bool marqueeOnScreen = false;
    void syncAnimationTimer() {
        const bool wanted = scheduler.active() || marqueeOnScreen;
        if (wanted && !animationTimerLive) {
            animationTimerLive = true;
            animationPumpStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            if (!animationPumpStop) {
                SetTimer(messageWindow, kAnimationTimer, 16, nullptr); // fallback
                return;
            }
            animationPump = std::thread([this] {
                for (;;) {
                    const DWORD r =
                        DCompositionWaitForCompositorClock(1, &animationPumpStop, 100);
                    if (r == WAIT_OBJECT_0) return; // stop event
                    if (r == WAIT_TIMEOUT) continue; // compositor idle: no frame due
                    if (r != WAIT_OBJECT_0 + 1) { // clock unavailable: ~60 Hz fallback
                        // WAIT_FAILED means the API never waited on our stop
                        // handle, so pace with a stop-aware wait instead of a
                        // blind Sleep — otherwise a persistent clock failure
                        // spins here forever and stopAnimationPump()'s join()
                        // (UI thread) deadlocks. animationPumpStop is
                        // manual-reset, so this latches the moment stop fires.
                        if (WaitForSingleObject(animationPumpStop, 16) == WAIT_OBJECT_0)
                            return;
                    }
                    // Auto-reset event: signaling while already signaled is a
                    // no-op, so a stalled UI thread coalesces ticks for free.
                    SetEvent(frameDue);
                }
            });
            return;
        }
        if (!wanted && animationTimerLive) {
            stopAnimationPump();
            animationTimerLive = false;
            return;
        }
    }

    // YBAR_DEBUG: measured animation frame rate, logged every ~2 s while the
    // pump runs. Counts full renderAll+Present passes, so it reads the
    // sustained end-to-end rate — coalescing drops it below the compositor
    // rate if a frame ever overruns its budget.
    int frameCount = 0;
    double frameWindowStart = 0;
    void traceFrameRate() {
        static const bool enabled = std::getenv("YBAR_DEBUG") != nullptr;
        if (!enabled) return;
        const double now = monotonicSeconds();
        if (frameWindowStart <= 0) {
            frameWindowStart = now;
            frameCount = 0;
            return;
        }
        ++frameCount;
        if (now - frameWindowStart >= 2.0) {
            std::fprintf(stderr, "[ybar:frames] %.1f fps sustained (animation clock)\n",
                         frameCount / (now - frameWindowStart));
            std::fflush(stderr);
            frameWindowStart = now;
            frameCount = 0;
        }
    }

    void stopAnimationPump() {
        if (animationPump.joinable()) {
            SetEvent(animationPumpStop);
            animationPump.join();
        }
        if (animationPumpStop) {
            CloseHandle(animationPumpStop);
            animationPumpStop = nullptr;
        }
        KillTimer(messageWindow, kAnimationTimer); // no-op unless fallback armed
        frameWindowStart = 0; // don't average a later run across the idle gap
    }

    // One animation frame: consumed by the message loop when frameDue signals.
    void runFrame() {
        scheduler.tick(monotonicSeconds());
        renderAll();
        traceFrameRate();
        syncAnimationTimer();
    }

    // Re-run every routine item's script once, ignoring the tick counters —
    // used on WM_TIMECHANGE so an os.date clock jumps to the new zone at once
    // instead of waiting up to its update_freq.
    void refreshRoutineItems() {
        for (const auto& item : store.items()) {
            if (item->updateFrequency <= 0) continue;
            if (item->script.empty() && !item->hasLuaHandlers) continue;
            if (item->updatePolicy == ybar::model::UpdatePolicy::Off) continue;
            if (bus.runItemScript)
                bus.runItemScript(*item,
                                  {{"NAME", item->name}, {"SENDER", "routine"}, {"INFO", ""}});
        }
    }

    // Re-read Transparency effects; if it flipped, re-apply the bar backdrops
    // and re-render so popups pick up the opaque flag (spec 7.6).
    void refreshSystemAppearance() {
        const bool now = ybar::win::systemTransparencyEnabled();
        if (now == systemTransparency) return;
        systemTransparency = now;
        for (const auto& surface : surfaces) surface->refreshBackdrop();
        renderAll();
    }

    ~DaemonState() { stopAnimationPump(); }

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
    // Resolve symlinks: winget's portable install runs the exe through a
    // Links-directory symlink, and GetModuleFileNameW reports the LINK path —
    // shaders/ and examples/ only exist next to the real file.
    const HANDLE file = CreateFileW(path.c_str(), 0, FILE_SHARE_READ | FILE_SHARE_WRITE,
                                    nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file != INVALID_HANDLE_VALUE) {
        wchar_t resolved[1024];
        const DWORD length = GetFinalPathNameByHandleW(file, resolved, 1024, FILE_NAME_NORMALIZED);
        CloseHandle(file);
        if (length > 0 && length < 1024) {
            std::wstring final(resolved, length);
            // \\?\UNC\server\share -> \\server\share; \\?\C:\... -> C:\...
            if (final.rfind(LR"(\\?\UNC\)", 0) == 0) final = L"\\\\" + final.substr(8);
            else if (final.rfind(LR"(\\?\)", 0) == 0) final = final.substr(4);
            path = final;
        }
    }
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
                    // Workspaces-widget contract: the focused monitor's
                    // workspace names, newline-separated, in komorebi order,
                    // plus the focused one's 1-based position — so a pill
                    // strip rebuilds without shelling out to komorebic.
                    {"WORKSPACES", update->workspaceNames},
                    {"FOCUSED_WORKSPACE_INDEX", std::to_string(update->focusedIndex)},
                };
                g_state->bus.trigger("komorebi_workspace_change", update->focusedWorkspace,
                                     env);
                g_state->bus.trigger("space_change", "", env);
                // A workspace switch changes the foreground window, so the
                // fullscreen auto-hide must re-evaluate now, not up to a second
                // later on the routine tick.
                g_state->updateFullscreenElevation();
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
                    // Same widget contract as the komorebi env: the shown
                    // workspace numbers (non-empty OR active) and the
                    // focused one's position in that list.
                    {"WORKSPACES", update->workspaceNames},
                    {"FOCUSED_WORKSPACE_INDEX", std::to_string(update->focusedIndex)},
                };
                // komorebi_workspace_change fires too so existing configs and
                // themes keep working unchanged, whichever WM is running.
                g_state->bus.trigger("ytile_workspace_change", update->focusedWorkspace, env);
                g_state->bus.trigger("komorebi_workspace_change", update->focusedWorkspace,
                                     env);
                g_state->bus.trigger("space_change", "", env);
                // A workspace switch changes the foreground window, so the
                // fullscreen auto-hide must re-evaluate now, not up to a second
                // later on the routine tick.
                g_state->updateFullscreenElevation();
            }
            delete update;
            return 0;
        }
        case WM_TIMECHANGE:
            // System time or time zone changed (incl. an automatic time-zone
            // update). Re-read the zone and refresh the clock now rather than
            // waiting for its next routine tick. Forwarded from a bar window —
            // a message-only window never receives the broadcast.
            if (g_state) {
                ::_tzset();
                g_state->refreshRoutineItems();
            }
            return 0;
        case WM_SETTINGCHANGE:
        case WM_THEMECHANGED:
            // Personalization changed — Transparency effects among them. A
            // no-op unless the transparency bit actually flipped.
            if (g_state) g_state->refreshSystemAppearance();
            return 0;
        case WM_TIMER:
            if (wParam == kRoutineTimer && g_state) {
                // Refresh the CRT timezone every tick so a clock built on
                // os.date tracks the OS zone: the UCRT caches it on first use
                // and does not re-read on a zone change (automatic time zone,
                // travel) until _tzset() is called. WM_TIMECHANGE gives the
                // instant update; this is the belt if a broadcast is missed.
                ::_tzset();
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
                g_state->recoverMissingSurfaces(); // a mode change can eat them
                g_state->detachKomorebiIfReserveChanged(); // reserve left WM mode
                g_state->tryAttachKomorebi(); // komorebi may have just started
                g_state->tryAttachYTile();    // ytile likewise (komorebi absent)
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
                // stop() before clearing (spec 11.4): the reader's reconnect
                // path re-applies the offset, and must be joined first.
                if (g_state && g_state->komorebi) {
                    g_state->komorebi->stop();
                    g_state->komorebi->clearWorkAreaOffset();
                }
                if (g_state && g_state->ytile) {
                    g_state->ytile->stop();
                    g_state->ytile->clearWorkAreaOffset();
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
            auto* payload = reinterpret_cast<KomorebiAppEvent*>(lParam);
            if (g_state) {
                // Resolve via the window first — same path as
                // front_app_switched — so the name comes from the process
                // that actually owns the window, not from a PATH search on
                // a bare basename. Destroy events have a dead window; the
                // exe basename is all komorebi still knows.
                std::string name =
                    ybar::providers::appNameForWindow(reinterpret_cast<void*>(payload->hwnd));
                if (name.empty())
                    name = ybar::providers::appNameForExecutablePath(payload->exe);
                if (!name.empty()) g_state->bus.trigger(payload->event, name);
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
        case ybar::win::BarSurface::kFullscreenCheckMessage:
            // ABN_FULLSCREENAPP relayed by an appbar surface (spec 6): the
            // shell's signal beats the 1 s geometry poll to the punch.
            if (g_state) g_state->updateFullscreenElevation();
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
                // The dragged item just ceased to exist — a stale id would
                // swallow every Move/Up on the bar from here on.
                g_state->draggingSliderId = -1;
                g_state->appliedOffsetPhysical = -1;
                g_state->executeConfig();
                g_state->detachKomorebiIfReserveChanged();
                g_state->renderAll();
                // Reload-mid-song contract (spec 10): replay the cached
                // media env so the rebuilt now-playing item repopulates —
                // identical PlaybackInfoChanged callbacks are deduped and
                // would never arrive again. Empty cache dispatches nothing.
                if (g_state->media) g_state->media->refresh();
                // Hotload watches the config's DIRECTORY — after --reload
                // <path> or `ybar theme use`, re-point it at the new one.
                if (g_state->hotloadEnabled)
                    g_state->hotload.setEnabled(true, g_state->resolvedConfigPath);
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
        if (!surface) {
            // Observed for real: a resolution change left every creation
            // failing here, and because this was a silent `continue` the bar
            // simply vanished for the rest of the session.
            // recoverMissingSurfaces() on the 1 s tick retries.
            std::fprintf(stderr, "[ybar] bar surface creation failed on display %d\n",
                         monitor.arrangementIndex);
            continue;
        }
        surfaces.push_back(std::move(surface));
    }
    surfaceFrames.assign(surfaces.size(), {});
    attachMouseHandlers();
    appliedOffsetPhysical = -1; // force the work-area handshake to re-run
    renderAll();
    // Freshly created surfaces start shown; if a fullscreen window already
    // covers a monitor (a display change while a game is up doesn't move the
    // foreground, so nothing else re-checks until the 1 s tick), re-apply the
    // fullscreen policy now so the rebuilt bar doesn't flash over it.
    updateFullscreenElevation();
}

// rebuildSurfaces() is a one-shot fired 500 ms after WM_DISPLAYCHANGE, and a
// display-mode change can still have DXGI refusing to create a swap chain at
// that point. When it does, every surface is already torn down and nothing
// retries: the bar disappears until the daemon is restarted. This was not
// theoretical — a 2880x1800 -> 1440x900 mode set killed the bar in exactly
// this way, leaving a live daemon serving IPC with zero windows and an empty
// log.
//
// So re-check from the 1 s tick, the same way komorebi is re-attached there.
// A rebuild costs an enumerate + create per second only while surfaces are
// actually missing, which is the situation where the alternative is no bar.
void DaemonState::recoverMissingSurfaces() {
    if (!renderer) return; // no GPU stack at all: IPC-only mode, nothing to do
    std::size_t wanted = 0;
    for (const auto& monitor : ybar::win::enumerateMonitors())
        if (settings.includesDisplay(monitor.arrangementIndex, monitor.primary)) ++wanted;
    // wanted == 0 is legitimate — every display excluded by config, or the
    // session momentarily has no monitors — and must not drive a rebuild loop.
    if (wanted == 0 || surfaces.size() >= wanted) {
        surfaceLossReported = false;
        surfaceRetryCountdown = 0;
        surfaceRetryDelay = 1;
        return;
    }
    if (surfaceRetryCountdown > 0) {
        --surfaceRetryCountdown;
        return;
    }
    if (!surfaceLossReported) {
        std::fprintf(stderr, "[ybar] %zu of %zu bar surfaces missing — rebuilding\n",
                     wanted - surfaces.size(), wanted);
        surfaceLossReported = true;
    }
    rebuildSurfaces();
    // Back off when the rebuild did not take. A transient mode change recovers
    // on the first or second try; a removed device never does, and retrying it
    // every second would only burn the GPU stack and the log.
    surfaceRetryDelay = surfaces.size() < wanted ? (std::min)(surfaceRetryDelay * 2, 60) : 1;
    surfaceRetryCountdown = surfaces.size() < wanted ? surfaceRetryDelay : 0;
}

// Subscribes to komorebi when it is running and we are not already attached.
// Re-tried from the 1 s tick, so starting komorebi after ybar attaches on its
// own instead of needing a daemon restart (spec 11.3).
bool DaemonState::tryAttachKomorebi() {
    if (komorebi) return false;
    if (settings.reserve == ybar::model::ReserveMode::Off ||
        settings.reserve == ybar::model::ReserveMode::AppBar)
        return false;
    if (!ybar::providers::KomorebiProvider::detect()) return false;
    // komorebi outranks ytile: if ytile got attached (komorebi was down at
    // its boot check) and komorebi has since appeared, hand over — komorebi
    // is the one actually tiling now.
    if (ytile) {
        ytile->stop();
        ytile->clearWorkAreaOffset();
        ytile.reset();
        appliedOffsetPhysical = -1;
    }

    komorebi = std::make_unique<ybar::providers::KomorebiProvider>();
    komorebi->onUpdate = [hwnd = messageWindow](const ybar::providers::KomorebiUpdate& update) {
        auto* copy = new ybar::providers::KomorebiUpdate(update);
        if (!PostMessageW(hwnd, kMsgKomorebi, 0, reinterpret_cast<LPARAM>(copy))) delete copy;
    };
    komorebi->onAppEvent = [hwnd = messageWindow](const std::string& event,
                                                  const std::string& exe, std::uintptr_t win) {
        auto* payload = new KomorebiAppEvent{event, exe, win};
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
    // Late attach publishes nothing until komorebi's next event — replay
    // current state now so a workspaces widget populates immediately
    // (delivery is marshaled through the normal onUpdate path).
    komorebi->refresh();
    // komorebi's Show/Destroy now feed app_launched/app_terminated — retire
    // the snapshot poller or every launch fires twice with different names.
    if (appLifecycleArmed) {
        KillTimer(messageWindow, kAppsTimer);
        appLifecycleArmed = false;
    }
    appliedOffsetPhysical = -1; // re-run the work-area handshake
    renderAll();
    return true;
}

// YTile attach (boot + the 1 s re-detect): only when komorebi is absent —
// komorebi outranks. A late-starting ytiled attaches the same way a late
// komorebi does, with an immediate state replay.
bool DaemonState::tryAttachYTile() {
    if (komorebi || ytile) return false;
    if (settings.reserve == ybar::model::ReserveMode::Off ||
        settings.reserve == ybar::model::ReserveMode::AppBar)
        return false;
    if (ybar::providers::KomorebiProvider::detect()) return false;
    if (!ybar::providers::YTileProvider::detect()) return false;

    ytile = std::make_unique<ybar::providers::YTileProvider>();
    ytile->onUpdate = [hwnd = messageWindow](const ybar::providers::YTileUpdate& update) {
        auto* copy = new ybar::providers::YTileUpdate(update);
        if (!PostMessageW(hwnd, kMsgYTile, 0, reinterpret_cast<LPARAM>(copy))) delete copy;
    };
    // Window lifecycle from state diffs rides the same resolution path as
    // komorebi's Show/Destroy (hwnd 0: unmanage windows are already gone,
    // the exe basename resolves deterministically).
    ytile->onAppEvent = [hwnd = messageWindow](const std::string& event,
                                               const std::string& exe) {
        auto* payload = new KomorebiAppEvent{event, exe, 0};
        if (!PostMessageW(hwnd, kMsgKomorebiApp, 0, reinterpret_cast<LPARAM>(payload)))
            delete payload;
    };
    bus.addEvent("ytile_workspace_change");
    bus.addEvent("komorebi_workspace_change"); // config compatibility
    if (!ytile->start()) {
        std::fprintf(stderr, "[ybar] ytile subscription failed\n");
        ytile.reset();
        return false;
    }
    trace("ytile: subscribed");
    // The reader pulls initial state itself right after subscribing, so no
    // explicit refresh is needed here; retire the app poller like komorebi.
    if (appLifecycleArmed) {
        KillTimer(messageWindow, kAppsTimer);
        appLifecycleArmed = false;
    }
    appliedOffsetPhysical = -1; // run the work-area handshake
    renderAll();
    return true;
}

// `--bar reserve=` can change at runtime (spec 6.1): leaving komorebi mode
// must release both the subscription and the reserved strip, or the offset
// double-stacks with the appbar / persists under reserve=off.
void DaemonState::detachKomorebiIfReserveChanged() {
    const bool komorebiMode = settings.reserve != ybar::model::ReserveMode::Off &&
                              settings.reserve != ybar::model::ReserveMode::AppBar;
    if (komorebiMode || (!komorebi && !ytile)) return;
    // stop() FIRST: it joins the reader thread, whose reconnect path would
    // otherwise re-apply the old offset right after our zeros land.
    if (komorebi) {
        komorebi->stop();
        komorebi->clearWorkAreaOffset();
        komorebi.reset();
    }
    if (ytile) {
        ytile->stop();
        ytile->clearWorkAreaOffset();
        ytile.reset();
    }
    appliedOffsetPhysical = -1;
    // The WM-less fallback poller resumes if anything still subscribes.
    const auto anySubscriber = [this](const char* name) {
        const auto bit = bus.eventBit(name);
        if (!bit) return false;
        for (const auto& item : store.items())
            if (item->updateMask & *bit) return true;
        return false;
    };
    if (!appLifecycleArmed &&
        (anySubscriber("app_launched") || anySubscriber("app_terminated"))) {
        appLifecycleArmed = true;
        appLifecycle.prime(); // never announce the existing world
        SetTimer(messageWindow, kAppsTimer, 2000, nullptr);
    }
}

// Fullscreen policy per monitor, re-evaluated on the 1 s tick, on the shell's
// ABN_FULLSCREENAPP signal, and on a workspace switch:
//   fullscreen_show=on  → raise the bar OVER the fullscreen window (never hide)
//   fullscreen_show=off → auto-hide the bar while a fullscreen window covers
//                         the monitor (the Win11-taskbar convention, and the
//                         analog of the macOS bar not showing over a
//                         fullscreen Space). Switching to a workspace without
//                         the fullscreen window changes the foreground, so the
//                         geometry test clears and the bar returns.
void DaemonState::updateFullscreenElevation() {
    for (const auto& surface : surfaces) {
        const bool fullscreen = surface->monitorHasFullscreenWindow();
        if (settings.fullscreenShow) {
            surface->setHiddenForFullscreen(false);
            surface->setFullscreenElevation(fullscreen);
        } else {
            surface->setFullscreenElevation(false);
            surface->setHiddenForFullscreen(fullscreen);
        }
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

// Split like the reference's publishPowerSource/publishBattery: `--trigger
// battery_change` must not also force-fire power_source_change subscribers.
void DaemonState::publishPowerSource(bool forced) {
    SYSTEM_POWER_STATUS status{};
    if (!GetSystemPowerStatus(&status)) return;
    // ACLineStatus: 0 battery, 1 AC, 255 unknown; PoHot maps to AC (spec 10).
    const std::string source = status.ACLineStatus == 0 ? "BATTERY" : "AC";
    if (forced || source != lastPowerSource) {
        lastPowerSource = source;
        bus.trigger("power_source_change", source);
    }
}

void DaemonState::publishBattery(bool forced) {
    SYSTEM_POWER_STATUS status{};
    if (!GetSystemPowerStatus(&status)) return;
    if (status.BatteryLifePercent == 255) return; // no battery / unknown
    const int percent = status.BatteryLifePercent;
    if (forced || percent != lastBatteryPercent) {
        lastBatteryPercent = percent;
        bus.trigger("battery_change", std::to_string(percent));
    }
}

void DaemonState::publishPower(bool forced) {
    publishPowerSource(forced);
    publishBattery(forced);
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

void DaemonState::sampleStats(bool publish) {
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
    // Silent prime (first-subscription arm): store the baseline, publish
    // nothing — the reference's first delivered sample is a genuine 2 s
    // delta, never a bogus CPU=0.
    if (!publish) return;

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
    // The bar frame includes the item's own padding; the content offset
    // covers alignment slack and the icon.
    const double trackX = frame->x + item.paddingLeft + sliderContentOffset(item);
    const double width = item.slider->width > 0 ? item.slider->width : 1;
    item.slider->percentage =
        std::min(100.0, std::max(0.0, (localX - trackX) / width * 100.0));
    if (renderer && !renderQueued) {
        renderQueued = true; // coalesce to one frame per turn (spec 7.2)
        PostMessageW(messageWindow, kMsgRender, 0, 0);
    }
}

// Content-relative offset of the slider track: alignment slack of a
// fixed-width item plus the icon advance — the same offsets the renderer
// applies before emitting the track.
double DaemonState::sliderContentOffset(const ybar::model::Item& item) {
    double offset = 0;
    if (item.customWidth >= 0 && fonts) {
        // Clamped to >= 0 while the emit side is unclamped — a deliberate
        // reference-parity choice: the Swift updateSlider clamps
        // (max(0, ...)) while its SceneBuilder shifts unclamped, so an
        // overflowing fixed-width slider mis-maps identically on macOS.
        const double slack =
            std::max(0.0, item.customWidth - ybar::model::naturalLength(item, measureItem(item)));
        if (item.align == 'c') offset += slack / 2;
        else if (item.align == 'r') offset += slack;
    }
    if (fonts && item.icon.drawing && !item.icon.displayString().empty()) {
        const auto& icon = fonts->shape(item.icon.displayString(), item.icon.font);
        offset += item.icon.paddingLeft + icon.width + item.icon.paddingRight;
    }
    return offset;
}

// Popup variant: content boxes are panel-local and already start after the
// member's paddingLeft, so only the content offset applies.
void DaemonState::updateSliderInPopup(ybar::model::Item& item, const LivePopup& live,
                                      double localX) {
    if (!item.slider || !fonts) return;
    const ybar::model::Rect* box = nullptr;
    for (std::size_t i = 0; i < live.memberIds.size(); ++i) {
        if (live.memberIds[i] == item.id && i < live.boxes.size()) {
            box = &live.boxes[i];
            break;
        }
    }
    if (!box) return;
    const double trackX = box->x + sliderContentOffset(item);
    const double width = item.slider->width > 0 ? item.slider->width : 1;
    item.slider->percentage =
        std::min(100.0, std::max(0.0, (localX - trackX) / width * 100.0));
    if (renderer && !renderQueued) {
        renderQueued = true;
        PostMessageW(messageWindow, kMsgRender, 0, 0);
    }
}

// The release side of a drag, shared by bar and popup paths: commit the
// percentage through click_script + mouse.clicked, then settle the global
// mouse containment the drag's veto suppressed.
void DaemonState::commitSliderRelease(ybar::model::Item& item) {
    const int percentage = static_cast<int>(std::lround(item.slider->percentage));
    ybar::events::Environment extra{{"PERCENTAGE", std::to_string(percentage)},
                                    {"BUTTON", "left"},
                                    {"MODIFIER", "none"}};
    if (!item.clickScript.empty()) {
        auto scriptEnv = extra;
        scriptEnv["NAME"] = item.name;
        scripts.run(item.clickScript, scriptEnv);
    }
    bus.triggerTargeted(item, "mouse.clicked", "", extra);
    if (globalMouseArmed) {
        POINT cursor{};
        GetCursorPos(&cursor);
        const bool inside = ybar::win::pointOverYBarWindow(cursor.x, cursor.y);
        if (inside != globalMouseInside) {
            globalMouseInside = inside;
            bus.trigger(inside ? "mouse.entered.global" : "mouse.exited.global", "");
        }
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
    // Same surface-pairing rule as popups: anchor at the surface that laid
    // the item out, not the first surface's origin with a foreign frame.
    std::ptrdiff_t surfaceIndex = -1;
    for (std::size_t i = 0; i < surfaces.size(); ++i) {
        if (frameFor(i, item.id)) {
            surfaceIndex = static_cast<std::ptrdiff_t>(i);
            break;
        }
    }
    if (surfaceIndex < 0) return;
    auto& surface = *surfaces[static_cast<std::size_t>(surfaceIndex)];
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

    // A frozen creation-scale tooltip mis-sizes after a DPI change — rebuild.
    if (tooltip && tooltip->scale() != scale) tooltip.reset();
    if (!tooltip) tooltip = ybar::win::PopupSurface::create(*renderer, scale);
    if (!tooltip) return;
    const auto* frame = frameFor(static_cast<std::size_t>(surfaceIndex), item.id);
    if (!frame) return;
    const auto origin = surface.screenOrigin();
    const ybar::model::Rect anchor{origin.x + frame->x * scale, origin.y + frame->y * scale,
                                   frame->width * scale, frame->height * scale};
    tooltip->present(panel, anchor, 'c', settings.position == ybar::model::BarPosition::Top, 4);
    renderer->render(list, tooltip->renderSurface(), atlas);
}

void DaemonState::hideTooltip() {
    if (tooltip) tooltip->hide();
    KillTimer(messageWindow, kTooltipTimer);
}

void DaemonState::releaseHoverIn(const LivePopup& popup) {
    if (hoverItemId == -1) return;
    for (const int id : popup.memberIds) {
        if (id != hoverItemId) continue;
        setHoverItem(nullptr);
        return;
    }
}

void DaemonState::setHoverItem(ybar::model::Item* item) {
    const int hoverId = item ? item->id : -1;
    if (hoverId == hoverItemId) return;
    hideTooltip();
    if (hoverItemId != -1) {
        for (const auto& candidate : store.items()) {
            if (candidate->id != hoverItemId) continue;
            candidate->mouseOver = false;
            bus.triggerTargeted(*candidate, "mouse.exited", "");
            break;
        }
    }
    if (item) {
        item->mouseOver = true;
        bus.triggerTargeted(*item, "mouse.entered", "");
        if (!item->tooltip.empty()) {
            tooltipItemId = item->id;
            SetTimer(messageWindow, kTooltipTimer, 600, nullptr);
        }
    }
    hoverItemId = hoverId;
}

void DaemonState::updatePopups() {
    if (!renderer || !fonts || surfaces.empty()) return;
    const auto measure = [this](const ybar::model::Item& item) { return measureItem(item); };

    // A popup belongs to the surface its host item is laid out on — the
    // reference pairs the same surface's frame, origin, and scale. Using the
    // first surface's origin with the last-rendered frame put popups off by
    // the monitors' width difference on mixed-width setups.
    const auto surfaceIndexForItem = [this](int itemId) -> std::ptrdiff_t {
        for (std::size_t i = 0; i < surfaces.size(); ++i)
            if (frameFor(i, itemId)) return static_cast<std::ptrdiff_t>(i);
        return -1;
    };

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
            releaseHoverIn(it->second);
            it->second.surface->hide();
            it = popups.erase(it);
        } else {
            ++it;
        }
    }

    for (const auto& host : store.items()) {
        const std::ptrdiff_t hostSurfaceIndex = surfaceIndexForItem(host->id);
        const bool wantsOpen = host->popup.isOpen && hostSurfaceIndex >= 0;
        auto liveIt = popups.find(host->id);
        if (!wantsOpen) {
            if (liveIt != popups.end()) {
                auto& live = liveIt->second;
                const double now = monotonicSeconds();
                if (live.closingUntil > 0) {
                    // Mid-fade: hold the entry until the compositor is done.
                    if (now < live.closingUntil) continue;
                } else if (host->popup.fadeOutFrames > 0) {
                    releaseHoverIn(live);
                    live.surface->fadeOut(host->popup.fadeOutFrames);
                    live.closingUntil = now + host->popup.fadeOutFrames / 60.0;
                    // A closing panel must stop answering the mouse at once,
                    // or the dismissing click lands in a ghost.
                    live.memberIds.clear();
                    live.boxes.clear();
                    continue;
                }
                releaseHoverIn(live);
                live.surface->hide();
                popups.erase(liveIt);
            }
            continue;
        }
        // Reopened before the fade finished: drop the closing state so the
        // present() below treats this as a fresh show and ramps back up.
        if (liveIt != popups.end() && liveIt->second.closingUntil > 0) {
            liveIt->second.closingUntil = 0;
            liveIt->second.surface->hide(); // re-arms the hidden->shown edge
        }
        auto& hostSurface = *surfaces[static_cast<std::size_t>(hostSurfaceIndex)];
        const double scale = hostSurface.scale();
        auto* atlas = atlasFor(scale);
        if (!atlas) continue;

        // A DPI change on the host monitor invalidates the popup surface's
        // frozen creation scale: rebuild it so present() sizes the window
        // and the mouse handler divides coordinates at the current scale.
        if (liveIt != popups.end() && liveIt->second.surface->scale() != scale) {
            releaseHoverIn(liveIt->second);
            liveIt->second.surface->hide();
            popups.erase(liveIt);
            liveIt = popups.end();
        }

        std::vector<ybar::model::Item*> members;
        for (const auto& member : store.items()) {
            if (member->position == ybar::model::ItemPosition::Popup &&
                member->popupHost == host->name && member->drawing)
                members.push_back(member.get());
        }
        if (members.empty()) {
            if (liveIt != popups.end()) {
                releaseHoverIn(liveIt->second);
                liveIt->second.surface->hide();
                popups.erase(liveIt);
            }
            continue;
        }

        const auto layout = ybar::model::layoutPopup(members, host->popup, measure);
        // Mica for the panel (spec 7.6) is decided before the surface exists:
        // it changes the scene (a material panel keeps its translucent plate
        // with Transparency effects off, where a plain one is forced opaque).
        const bool mica = ybar::win::PopupSurface::backdropsAvailable();
        auto scene = ybar::render::buildPopupScene(members, layout.contentBoxes, host->popup,
                                                   layout.panelSize, scale, *fonts, *atlas,
                                                   /*opaquePanel=*/!systemTransparency,
                                                   /*backdrops=*/mica);
        if (scene.empty()) { // never leave a stale, still-clickable panel
            if (liveIt != popups.end()) {
                releaseHoverIn(liveIt->second);
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
                    using Kind = ybar::win::MouseEvent::Kind;
                    const auto it = popups.find(hostId);

                    // The shared slider drag machinery works here verbatim —
                    // only the frame source differs (spec 3.9, mirroring the
                    // reference's popup press/drag routing). Runs BEFORE the
                    // dead-popup early-return so a popup erased mid-drag
                    // still ends its drag cleanly.
                    if (draggingSliderId != -1 &&
                        (event.kind == Kind::Move || event.kind == Kind::Up)) {
                        bool handled = false;
                        for (const auto& candidate : store.items()) {
                            if (candidate->id != draggingSliderId || !candidate->slider)
                                continue;
                            if (it == popups.end()) { // popup died mid-drag
                                candidate->slider->isDragged = false;
                                break;
                            }
                            handled = true;
                            const bool released = event.kind == Kind::Up;
                            candidate->slider->isDragged = !released;
                            updateSliderInPopup(*candidate, it->second, event.x);
                            if (released) {
                                draggingSliderId = -1;
                                commitSliderRelease(*candidate);
                            }
                            break;
                        }
                        if (handled) return;
                        // Self-heal a stale drag id; a release must never
                        // become a click on whatever sits under the cursor.
                        draggingSliderId = -1;
                        if (event.kind == Kind::Up) return;
                    }
                    if (it == popups.end()) return;
                    const auto memberAt = [this, &it](double x,
                                                      double y) -> ybar::model::Item* {
                        for (std::size_t i = 0; i < it->second.boxes.size(); ++i) {
                            if (!it->second.boxes[i].contains({x, y})) continue;
                            for (const auto& item : store.items())
                                if (item->id == it->second.memberIds[i]) return item.get();
                            return nullptr;
                        }
                        return nullptr;
                    };
                    // Row hover, the same targeted transition the bar does.
                    // Popup rows are the densest clickable surface in the
                    // product and had no affordance at all before this.
                    if (event.kind == Kind::Move || event.kind == Kind::Leave) {
                        auto* member =
                            event.kind == Kind::Leave ? nullptr : memberAt(event.x, event.y);
                        setHoverItem(member);
                        if (event.kind == Kind::Leave) return;
                    }
                    if (event.kind == Kind::Down) {
                        auto* member = memberAt(event.x, event.y);
                        // Same read-only rule inside popups (spec 3.9).
                        if (member && member->slider && member->slider->interactive) {
                            draggingSliderId = member->id;
                            member->slider->isDragged = true;
                            scheduler.cancel("item." + std::to_string(member->id) +
                                             ".slider.percentage");
                            updateSliderInPopup(*member, it->second, event.x);
                        }
                        return; // press inside a popup never dismisses it (spec 3.9)
                    }
                    if (event.kind == Kind::Up) {
                        if (auto* member = memberAt(event.x, event.y))
                            dispatchClick(*member, event.button, event.modifier);
                    }
                });
        }
        auto& live = liveIt->second;
        live.memberIds.clear();
        for (auto* member : members) live.memberIds.push_back(member->id);
        live.boxes = layout.contentBoxes;

        // Anchor from the SAME surface's frame snapshot — item->frame holds
        // whichever monitor rendered last, not necessarily this one.
        const auto* hostFrame =
            frameFor(static_cast<std::size_t>(hostSurfaceIndex), host->id);
        if (!hostFrame) continue;
        const auto origin = hostSurface.screenOrigin();
        const ybar::model::Rect anchor{origin.x + hostFrame->x * scale,
                                       origin.y + hostFrame->y * scale,
                                       hostFrame->width * scale, hostFrame->height * scale};
        // DWM Acrylic only stands in where the Mica layer cannot (no
        // wallpaper brush, i.e. Windows 10); with the layer the panel's
        // material is in the scene's backdrops.
        live.surface->setBackdrop(host->popup.blurRadius > 0 && !mica,
                                  host->popup.background.cornerRadius);
        live.surface->present(layout.panelSize, anchor, host->popup.align,
                              settings.position == ybar::model::BarPosition::Top,
                              host->popup.yOffset,
                              host->popup.fadeInFrames);
        live.surface->setBackdrops(scene.backdrops);
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
    // Shaped-line eviction happens HERE, not inside FontCache::shape(). This
    // is the one point in the frame where no ShapedLine reference is live:
    // shape() hands out references into its map, clear() is what invalidates
    // them, and both the layout measure below and emitItem hold two shaped
    // lines at once. Nothing re-enters the frame either — the message pump is
    // drained before runFrame(), and renderAll() never pumps.
    fonts->beginFrame();
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
        if (pointerSurface == surfaceIndex) {
            params.pointerX = pointerX;
            params.pointerY = pointerY;
        }
        params.backdrops = surface->supportsBackdrops();
        trace("renderAll: buildScene");
        const auto list =
            ybar::render::buildScene(store.items(), boxes, settings, params, *fonts, *atlas);
        trace("renderAll: render");
        if (list.hasMarquee) marqueeOnScreen = true; // keeps the clock running
        // Arms the pointer-light path for the NEXT mouse move. Cheap: a scan
        // of one frame's quads, and it short-circuits on the first glass one.
        if (surfaceIndex == 0) pointerLightActive = false;
        for (const auto& quad : list.quads) {
            if (quad.flags & ybar::render::kQuadFlagGlass) {
                pointerLightActive = true;
                break;
            }
        }
        // The backdrop layer under the swap chain follows the pills it was
        // cut for (spec 7.6). Change-guarded inside, so this is free while
        // the layout holds still.
        surface->setBackdrops(list.backdrops);
        if (!renderer->render(list, surface->renderSurface(), atlas)) {
            SetTimer(messageWindow, kRenderRetryTimer, 1000, nullptr); // spec 7.2
        }
        trace("renderAll: surface done");
    }

    updatePopups();

    // Work-area handshake follows bar-height changes (spec 11.4). Reserve
    // leaving komorebi mode zeroes the offset — otherwise it double-stacks
    // with the appbar or persists under reserve=off.
    if ((komorebi || ytile) && !surfaces.empty()) {
        const bool reserving = settings.reserve != ybar::model::ReserveMode::Off &&
                               settings.reserve != ybar::model::ReserveMode::AppBar;
        const double scale = surfaces.front()->scale();
        const int physical = (settings.hidden || !reserving)
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
                bool handled = false;
                for (const auto& candidate : state.store.items()) {
                    if (candidate->id != state.draggingSliderId || !candidate->slider) continue;
                    // No frame on this bar means the drag belongs to a popup
                    // that died mid-drag — heal instead of swallowing bar
                    // input on an item the bar never laid out.
                    if (!state.frameFor(surfaceIndex, candidate->id)) {
                        candidate->slider->isDragged = false;
                        break;
                    }
                    handled = true;
                    const bool released = event.kind == Kind::Up;
                    candidate->slider->isDragged = !released;
                    state.updateSlider(*candidate, surfaceIndex, event.x);
                    if (released) {
                        state.draggingSliderId = -1;
                        state.commitSliderRelease(*candidate);
                    }
                    break;
                }
                if (handled) return;
                // Self-heal: the dragged item was removed mid-drag (reload,
                // --remove). Drop the stale id; consume a release outright —
                // an Up that began a slider drag must never turn into a
                // click on whatever item sits under the cursor.
                state.draggingSliderId = -1;
                if (event.kind == Kind::Up) return;
            }

            auto* item = event.kind == Kind::Leave ? nullptr : hitTest(event.x, event.y);

            // Hover transitions (mouse.entered / mouse.exited) + tooltip dwell.
            state.setHoverItem(item);

            // Pointer-tracked key light. renderAll() is a FULL re-layout and
            // re-encode, so this is gated three ways: only when a glass quad
            // is actually on screen, only past a minimum travel, and never
            // faster than the 60 Hz frame clock. Without all three a pointer
            // crossing the bar would re-shape every string on it at the
            // mouse's own report rate, which is 125 Hz and up.
            if (state.pointerLightActive) {
                if (event.kind == Kind::Leave) {
                    if (state.pointerX >= 0) {
                        state.pointerX = -1;
                        state.pointerY = -1;
                        state.pointerSurface = static_cast<std::size_t>(-1);
                        state.renderAll();
                    }
                } else if (event.kind == Kind::Move) {
                    const double now = monotonicSeconds();
                    const bool moved = state.pointerSurface != surfaceIndex ||
                                       std::abs(event.x - state.pointerX) >= 3.0 ||
                                       std::abs(event.y - state.pointerY) >= 3.0;
                    state.pointerX = event.x;
                    state.pointerY = event.y;
                    state.pointerSurface = surfaceIndex;
                    if (moved && now - state.lastPointerRender >= 1.0 / 60.0) {
                        state.lastPointerRender = now;
                        state.renderAll();
                    }
                }
            }

            // A press ANYWHERE on the bar — including empty space — closes
            // auto-close popups except the pressed host's (spec 3.9).
            if (event.kind == Kind::Down) {
                state.closeAutoClosePopups(item ? item->id : -1);
                // interactive=off is a read-only meter: no drag, and no
                // pointer-derived percentage overwrite (spec 3.9).
                if (item && item->slider && item->slider->interactive) {
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

    // YTile: the sibling WM adapter. komorebi WINS when both answer — in
    // practice ytiled can idle alongside (launched by whkd) while komorebi
    // does the actual tiling. ytile attaches only when komorebi is absent,
    // here at boot and from the 1 s re-detect tick.
    state.tryAttachYTile();

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
            state.sampleStats(/*publish=*/false); // silent prime of the deltas
            SetTimer(state.messageWindow, kStatsTimer, 2000, nullptr);
        } else if (event == "volume_change") {
            state.armAudio();
        } else if (event == "wifi_change") {
            state.armNetwork();
        } else if (event == "media_change") {
            state.armMedia();
        } else if (event == "app_launched" || event == "app_terminated") {
            // komorebi (Show/Destroy) and YTile (manage/unmanage diffs) already
            // feed these; the poller is only for the WM-less case (spec 10).
            // Testing komorebi alone let the poller arm beside a live YTile
            // subscription, so every launch fired twice with different names.
            if (!state.komorebi && !state.ytile && !state.appLifecycleArmed) {
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
    hooks.komorebiMessage = [&state](const std::string& jsonText) {
        if (ybar::providers::KomorebiProvider::detect())
            return ybar::providers::KomorebiProvider::sendMessage(jsonText);
        // YTile compatibility: with komorebi absent, translate the workspace
        // SocketMessage types themes actually send onto YTile verbs, so the
        // same click_script drives either WM unchanged.
        if (state.ytile) {
            try {
                const auto message = nlohmann::json::parse(jsonText);
                const auto type = message.value("type", std::string{});
                if (type == "FocusWorkspaceNumber")
                    return state.ytile->focusListIndex(message.value("content", 0));
                if (type == "FocusNamedWorkspace")
                    return state.ytile->focusNamed(message.value("content", std::string{}));
                if (type == "CycleFocusWorkspace")
                    return state.ytile->cycleWorkspace(
                        message.value("content", std::string{"Next"}) != "Previous");
            } catch (const nlohmann::json::exception&) {
            }
        }
        return false;
    };
    hooks.reload = [&state](const std::string& explicitPath) {
        // --reload [path] re-points the config before the teardown re-run —
        // but only to a file that exists. A typo'd path must not become the
        // sticky config source and blank the bar forever (the reference just
        // re-runs the old config on a bad path).
        if (!explicitPath.empty()) {
            if (ybar::app::configFileExists(explicitPath)) {
                state.explicitConfigPath = explicitPath;
            } else {
                std::fprintf(stderr, "[!] config not found: %s\n", explicitPath.c_str());
            }
        }
        PostMessageW(state.messageWindow, kMsgReloadConfig, 0, 0);
    };
    hooks.setHotload = [&state](bool enabled) {
        state.hotloadEnabled = enabled;
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
        if (event == "power_source_change") {
            state.publishPowerSource(true); // only the requested event fires
            return true;
        }
        if (event == "battery_change") {
            state.publishBattery(true);
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
    // Running-app list for the tray widget (spec 10.6). Both run inline: the
    // IPC request is already marshaled to this thread, and an enumeration
    // pass is milliseconds.
    hooks.runningApps = [] {
        return ybar::providers::serializeRunningApps(ybar::providers::runningApps());
    };
    hooks.windowAction = [](long long hwnd, const std::string& action) {
        return ybar::providers::windowAction(hwnd, action);
    };
    // Notification-area icons (spec 10.6). Also inline: a UIA pass measures
    // ~15-20 ms, well under the IPC round trip that carries it.
    hooks.trayIcons = [] {
        return ybar::providers::serializeTrayIcons(ybar::providers::trayIcons());
    };
    hooks.trayInvoke = [](const std::string& name) {
        return ybar::providers::invokeTrayIcon(name);
    };
    hooks.trayClose = [](const std::string& name) {
        return ybar::providers::closeTrayApp(name);
    };
    // Master-volume set (spec 10, Audio row). armAudio() first, matching the
    // forcedQuery precedent, so --volume works before anything subscribes to
    // volume_change; the resulting OnNotify publishes the new value back.
    hooks.setVolume = [&state](int percent) {
        state.armAudio();
        return state.audio && state.audio->setVolume(percent);
    };
    // Per-app session groups (spec 10, Audio row). Stateless enumeration
    // passes, independent of the master AudioProvider — no armAudio().
    hooks.audioSessions = [] {
        return ybar::providers::serializeAudioSessionGroups(
            ybar::providers::audioSessionGroups());
    };
    hooks.setAppVolume = [](const std::string& id, int percent) {
        return ybar::providers::setAudioSessionVolume(id, percent);
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

    // Must exist before the first render: a marquee on the boot frame starts
    // the pump, which signals this event from its thread.
    state.frameDue = CreateEventW(nullptr, FALSE, FALSE, nullptr); // auto-reset

    SetTimer(state.messageWindow, kRoutineTimer, 1000, nullptr);
    state.executeConfig();
    if (state.renderer) state.renderAll(); // first frame

    // Input-priority loop: drain EVERY pending message (hardware input,
    // posted work, timers) before consuming an animation frame. GetMessage
    // ranks posted messages above input, so pumping frames through
    // PostMessage starved clicks whenever render time approached the frame
    // budget — with a marquee running, popup-opening clicks lagged visibly.
    // Worst case here is one frame of input delay (MsgWait prefers handles),
    // never starvation: the drain always runs before the next frame.
    MSG msg;
    bool running = true;
    while (running) {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                running = false;
                break;
            }
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if (!running) break;
        const DWORD wait = MsgWaitForMultipleObjectsEx(1, &state.frameDue, INFINITE,
                                                       QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (wait == WAIT_OBJECT_0) state.runFrame();
        // WAIT_OBJECT_0 + 1: new messages arrived — loop back to the drain.
    }

    if (frontAppHook) UnhookWinEvent(frontAppHook);
    if (state.mouseHook) UnhookWindowsHookEx(static_cast<HHOOK>(state.mouseHook));
    if (state.keyboardHook) UnhookWindowsHookEx(static_cast<HHOOK>(state.keyboardHook));
    state.stopAnimationPump(); // join before the window (and state) go away
    if (state.frameDue) {
        CloseHandle(state.frameDue);
        state.frameDue = nullptr;
    }
    server.stop();
    DestroyWindow(state.messageWindow);
    g_state = nullptr;
    return 0;
}

} // namespace ybar::app
