#include "app/daemon.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <winsock2.h>
#include <windows.h>
// clang-format on

#include <cstdio>
#include <cstdlib>
#include <future>
#include <memory>
#include <unordered_map>

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
#include "providers/komorebi.h"
#include "providers/ytile.h"
#include "render/font_cache.h"
#include "render/glyph_atlas.h"
#include "render/renderer.h"
#include "render/scene_builder.h"
#include "win/bar_surface.h"
#include "win/display_manager.h"

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
constexpr UINT_PTR kStatsTimer = 5;

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

    // Providers (spec 10): dedupe state.
    std::string lastPowerSource;
    int lastBatteryPercent = -1;
    std::string lastFrontApp;
    ULONGLONG statsPrevIdle = 0, statsPrevKernel = 0, statsPrevUser = 0;
    bool statsArmed = false;

    void executeConfig();
    void publishPower(bool forced);
    void publishFrontApp(bool forced);
    void sampleStats();

    // On-demand animation clock: runs only while animations exist (spec 7.2).
    void syncAnimationTimer() {
        if (scheduler.active() && !animationTimerLive) {
            SetTimer(messageWindow, kAnimationTimer, 16, nullptr);
            animationTimerLive = true;
        } else if (!scheduler.active() && animationTimerLive) {
            KillTimer(messageWindow, kAnimationTimer);
            animationTimerLive = false;
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
                g_state->syncAnimationTimer();
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
                for (const auto& item : g_state->store.items()) {
                    if (item->updateFrequency <= 0) continue;
                    if (++item->routineCounter < item->updateFrequency) continue;
                    item->routineCounter = 0;
                    if (item->updatePolicy == ybar::model::UpdatePolicy::Off) continue;
                    if (item->updatePolicy == ybar::model::UpdatePolicy::WhenShown &&
                        !item->drawing)
                        continue;
                    if (g_state->bus.runItemScript &&
                        (!item->script.empty() || item->hasLuaHandlers)) {
                        g_state->bus.runItemScript(
                            *item, {{"NAME", item->name}, {"SENDER", "routine"}, {"INFO", ""}});
                    }
                }
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
        case WM_FONTCHANGE:
            // Broadcasts reach the BAR windows, not this message-only window
            // (spec 7.4) — but handle it here too in case of direct sends.
            if (g_state && g_state->fonts) g_state->fonts->clear();
            return 0;
        case WM_ENDSESSION:
            if (wParam) PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

void CALLBACK foregroundHook(HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD) {
    if (g_state) g_state->publishFrontApp(false); // delivered on the UI thread
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
    std::string name;
    if (const HWND foreground = GetForegroundWindow()) {
        DWORD processId = 0;
        GetWindowThreadProcessId(foreground, &processId);
        if (const HANDLE process =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId)) {
            wchar_t path[MAX_PATH];
            DWORD size = MAX_PATH;
            if (QueryFullProcessImageNameW(process, 0, path, &size)) {
                std::wstring wide(path, size);
                const auto slash = wide.find_last_of(L"\\/");
                if (slash != std::wstring::npos) wide = wide.substr(slash + 1);
                if (wide.size() > 4) wide.resize(wide.size() - 4); // strip .exe
                const int utf8Size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr,
                                                         0, nullptr, nullptr);
                name.resize(static_cast<std::size_t>(utf8Size - 1));
                WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, name.data(), utf8Size,
                                    nullptr, nullptr);
            }
            CloseHandle(process);
        }
    }
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

void DaemonState::renderAll() {
    if (!renderer || !fonts) return;
    trace("renderAll: begin");
    for (auto& surface : surfaces) {
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
        const auto boxes = ybar::model::layout(store.items(), layoutSettings, measure);

        ybar::render::SceneParams params{surface->logicalWidth(), surface->logicalHeight(),
                                         scale};
        trace("renderAll: buildScene");
        const auto list =
            ybar::render::buildScene(store.items(), boxes, settings, params, *fonts, *atlas);
        trace("renderAll: render");
        if (!renderer->render(list, surface->renderSurface(), atlas)) {
            SetTimer(messageWindow, kRenderRetryTimer, 1000, nullptr); // spec 7.2
        }
        trace("renderAll: surface done");
    }

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
    for (auto& surface : state.surfaces) {
        surface->setMouseHandler([&state](const ybar::win::MouseEvent& event) {
            auto hitTest = [&state](double x, double y) -> ybar::model::Item* {
                const auto& items = state.store.items();
                for (auto it = items.rbegin(); it != items.rend(); ++it) {
                    auto* item = it->get();
                    if (item->kind == ybar::model::ItemKind::Bracket) continue;
                    if (item->position == ybar::model::ItemPosition::Popup) continue;
                    if (!item->frame.isZero() && item->frame.contains({x, y})) return item;
                }
                return nullptr;
            };
            using Kind = ybar::win::MouseEvent::Kind;
            auto* item = event.kind == Kind::Leave ? nullptr : hitTest(event.x, event.y);

            // Hover transitions (mouse.entered / mouse.exited).
            const int hoverId = item ? item->id : -1;
            if (hoverId != state.hoverItemId) {
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
                }
                state.hoverItemId = hoverId;
            }
            if (!item) return;

            if (event.kind == Kind::Up) { // clicks fire on mouse-UP (spec 3.5)
                const std::string info = std::string("{\"button\":\"") + event.button +
                                         "\",\"modifier\":\"" + event.modifier + "\"}";
                ybar::events::Environment extra{{"BUTTON", event.button},
                                                {"MODIFIER", event.modifier}};
                state.bus.triggerTargeted(*item, "mouse.clicked", info, extra);
                if (!item->clickScript.empty()) {
                    extra["NAME"] = item->name;
                    extra["INFO"] = info;
                    state.scripts.run(item->clickScript, extra);
                }
            } else if (event.kind == Kind::Scroll) {
                state.bus.triggerTargeted(*item, "mouse.scrolled", "",
                                          {{"SCROLL_DELTA", std::to_string(event.scrollDelta)},
                                           {"MODIFIER", event.modifier}});
            }
        });
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
    if (!state.ytile && state.settings.reserve != ybar::model::ReserveMode::Off &&
        state.settings.reserve != ybar::model::ReserveMode::AppBar &&
        ybar::providers::KomorebiProvider::detect()) {
        state.komorebi = std::make_unique<ybar::providers::KomorebiProvider>();
        state.komorebi->onUpdate = [hwnd = state.messageWindow](
                                       const ybar::providers::KomorebiUpdate& update) {
            auto* copy = new ybar::providers::KomorebiUpdate(update);
            if (!PostMessageW(hwnd, kMsgKomorebi, 0, reinterpret_cast<LPARAM>(copy)))
                delete copy;
        };
        state.bus.addEvent("komorebi_workspace_change");
        if (!state.komorebi->start("ybar.sock")) {
            std::fprintf(stderr, "[ybar] komorebi subscription failed\n");
            state.komorebi.reset();
        } else {
            trace("komorebi: subscribed");
        }
    }

    // System providers (spec 10): power push notifications + front-app hook
    // always on; stats armed lazily on first subscription.
    RegisterPowerSettingNotification(state.messageWindow, &kGuidAcDcPowerSource,
                                     DEVICE_NOTIFY_WINDOW_HANDLE);
    RegisterPowerSettingNotification(state.messageWindow, &kGuidBatteryPercentage,
                                     DEVICE_NOTIFY_WINDOW_HANDLE);
    const HWINEVENTHOOK frontAppHook =
        SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr,
                        foregroundHook, 0, 0, WINEVENT_OUTOFCONTEXT);
    state.bus.onFirstSubscription = [&state](const std::string& event) {
        if (event == "system_stats" && !state.statsArmed) {
            state.statsArmed = true;
            state.sampleStats(); // prime the tick deltas
            SetTimer(state.messageWindow, kStatsTimer, 2000, nullptr);
        }
    };
    ybar::win::BarSurface::setBroadcastTarget(state.messageWindow);
    state.hotload.onChange = [hwnd = state.messageWindow] {
        PostMessageW(hwnd, kMsgReloadConfig, 0, 0);
    };

    ybar::ipc::DaemonHooks hooks;
    hooks.exit = [hwnd = state.messageWindow] { SetTimer(hwnd, kExitTimer, 150, nullptr); };
    hooks.komorebiMessage = [](const std::string& jsonText) {
        return ybar::providers::KomorebiProvider::detect() &&
               ybar::providers::KomorebiProvider::sendMessage(jsonText);
    };
    hooks.reload = [hwnd = state.messageWindow] {
        PostMessageW(hwnd, kMsgReloadConfig, 0, 0);
    };
    hooks.setHotload = [&state](bool enabled) {
        state.hotload.setEnabled(enabled, state.resolvedConfigPath);
    };
    hooks.forcedUpdate = [&state] {
        state.publishPower(true);
        state.publishFrontApp(true);
        if (state.statsArmed) state.sampleStats();
    };
    hooks.forcedQuery = [&state](const std::string& event) {
        // The --trigger interception set (spec 3.4); unsupported providers
        // (volume/wifi/media) fall through to plain bus triggers for now.
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
        return false;
    };
    hooks.setNeedsRender = [&state] {
        if (state.renderQueued || !state.renderer) return;
        state.renderQueued = true; // coalesce to one frame per turn (spec 7.2)
        PostMessageW(state.messageWindow, kMsgRender, 0, 0);
    };
    hooks.displays = [] { return ybar::win::displayInfos(); };
    hooks.boundingRects = [&state](const ybar::model::Item& item) {
        ybar::model::BoundingRects rects;
        for (const auto& surface : state.surfaces) {
            if (!item.frame.isZero())
                rects[surface->monitor().arrangementIndex] = item.frame;
        }
        return rects;
    };
    state.handler = std::make_unique<ybar::ipc::CommandHandler>(state.store, state.settings,
                                                                state.bus, hooks,
                                                                &state.scheduler);
    state.lua = std::make_unique<ybar::lua::LuaRuntime>(state.store, state.bus, *state.handler,
                                                        state.scripts, state.messageWindow);

    ybar::ipc::SocketServer server;
    const auto socketPath = ybar::ipc::socketPath(instance);
    const auto error = server.start(socketPath, [hwnd = state.messageWindow](
                                                    const std::vector<std::string>& argv) {
        auto request = std::make_unique<IpcRequest>();
        request->argv = argv;
        auto future = request->reply.get_future();
        if (!PostMessageW(hwnd, kMsgIpcRequest, 0, reinterpret_cast<LPARAM>(request.get())))
            return std::string();
        request.release(); // UI thread owns it now and deletes after replying
        return future.get();
    });
    if (error) {
        std::fprintf(stderr, "%s\n", error->c_str());
        return 1;
    }

    SetTimer(state.messageWindow, kRoutineTimer, 1000, nullptr);
    state.executeConfig();
    if (state.renderer) state.renderAll(); // first frame

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (frontAppHook) UnhookWinEvent(frontAppHook);
    server.stop();
    DestroyWindow(state.messageWindow);
    g_state = nullptr;
    return 0;
}

} // namespace ybar::app
