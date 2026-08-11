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

#include "app/script_runner.h"
#include "events/event_bus.h"
#include "ipc/command_handler.h"
#include "ipc/socket.h"
#include "ipc/wire_format.h"
#include "model/bar_settings.h"
#include "model/item.h"
#include "model/layout.h"
#include "providers/komorebi.h"
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
constexpr UINT_PTR kRoutineTimer = 1;
constexpr UINT_PTR kExitTimer = 2;
constexpr UINT_PTR kRenderRetryTimer = 3;

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
    int appliedOffsetPhysical = -1;
    int hoverItemId = -1; // targeted mouse.entered/exited tracking

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
                PostQuitMessage(0);
            } else if (wParam == kRenderRetryTimer && g_state) {
                KillTimer(hwnd, kRenderRetryTimer);
                g_state->renderAll();
            }
            return 0;
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

} // namespace

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
    if (komorebi && !surfaces.empty()) {
        const double scale = surfaces.front()->scale();
        const int physical = settings.hidden
                                 ? 0
                                 : static_cast<int>((settings.height + settings.yOffset) * scale + 0.5);
        if (physical != appliedOffsetPhysical) {
            appliedOffsetPhysical = physical;
            komorebi->applyWorkAreaOffset(physical);
        }
    }
}

int runDaemon(const std::string& instance, const std::string& configPath) {
    (void)configPath; // config execution lands with the ScriptRunner slice

    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    DaemonState state;
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

    // Scripts: the event bus dispatches through the ScriptRunner (spec 10.1).
    state.bus.itemsProvider = [&state] {
        std::vector<ybar::model::Item*> items;
        for (const auto& item : state.store.items()) items.push_back(item.get());
        return items;
    };
    state.bus.runItemScript = [&state](ybar::model::Item& item,
                                       const ybar::events::Environment& env) {
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

    // komorebi (spec 11): subscription + work-area handshake, gated by reserve.
    if (state.settings.reserve != ybar::model::ReserveMode::Off &&
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

    ybar::ipc::DaemonHooks hooks;
    hooks.exit = [hwnd = state.messageWindow] { SetTimer(hwnd, kExitTimer, 150, nullptr); };
    hooks.komorebiMessage = [](const std::string& jsonText) {
        return ybar::providers::KomorebiProvider::detect() &&
               ybar::providers::KomorebiProvider::sendMessage(jsonText);
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
                                                                state.bus, hooks);

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
    if (state.renderer) state.renderAll(); // first frame

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    server.stop();
    DestroyWindow(state.messageWindow);
    g_state = nullptr;
    return 0;
}

} // namespace ybar::app
