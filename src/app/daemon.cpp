#include "app/daemon.h"

// clang-format off
#include <winsock2.h>
#include <windows.h>
// clang-format on

#include <cstdio>
#include <future>
#include <memory>

#include "events/event_bus.h"
#include "ipc/command_handler.h"
#include "ipc/socket.h"
#include "ipc/wire_format.h"
#include "model/bar_settings.h"
#include "model/item.h"

namespace ybar::app {

namespace {

constexpr UINT kMsgIpcRequest = WM_APP + 1;
constexpr UINT_PTR kRoutineTimer = 1;
constexpr UINT_PTR kExitTimer = 2;

// One marshaled IPC request: the accept thread waits on the promise while the
// UI thread executes the handler (spec 5: the DispatchQueue.main.sync
// equivalent, deadlock-free by construction).
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
};

DaemonState* g_state = nullptr;

LRESULT CALLBACK messageWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
        case kMsgIpcRequest: {
            // UI thread owns the request from here: set the reply, then free.
            // The future's shared state outlives the promise, so the waiting
            // accept thread is unaffected by the deletion.
            auto* request = reinterpret_cast<IpcRequest*>(lParam);
            std::string reply;
            if (g_state && g_state->handler) reply = g_state->handler->handle(request->argv);
            request->reply.set_value(std::move(reply));
            delete request;
            return 0;
        }
        case WM_TIMER:
            if (wParam == kRoutineTimer && g_state) {
                // update_freq routine tick (SENDER=routine); script dispatch
                // arrives with the ScriptRunner slice — counters still advance
                // so update_freq semantics are observable via --query.
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
                PostQuitMessage(0);
            }
            return 0;
        case WM_ENDSESSION:
            if (wParam) PostQuitMessage(0);
            return 0;
        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

} // namespace

int runDaemon(const std::string& instance, const std::string& configPath) {
    (void)configPath; // config execution lands with the ScriptRunner slice

    DaemonState state;
    g_state = &state;

    // Hidden message-only window: the UI-thread mailbox. (Broadcast messages
    // like WM_FONTCHANGE do NOT reach it — bar windows handle those.)
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

    ybar::ipc::DaemonHooks hooks;
    hooks.exit = [hwnd = state.messageWindow] {
        // Reply first; terminate ~150 ms later so the IPC reply flushes.
        SetTimer(hwnd, kExitTimer, 150, nullptr);
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
