// Embedded Lua 5.4 config runtime (spec sections 3.7, 12) — the reference
// LuaRuntime.swift design ported to C++/Win32:
//  - one lua_State on the UI thread; trampolines never call raising luaL_*
//    APIs (longjmp through C++ frames skips destructors — same invariant)
//  - subscriptions are registry refs keyed per item-id per event-name;
//    SENDER=forced falls back to the item's "routine" handler
//  - exec/delay completions are generation-guarded across config reloads
//  - most operations funnel through CommandHandler — the same entry point
//    socket clients hit, so setter semantics stay defined once

#pragma once

#include <map>
#include <memory>
#include <string>

#include "events/event_bus.h"
#include "ipc/command_handler.h"
#include "model/item.h"

struct lua_State;

namespace ybar::app {
class ScriptRunner;
}

namespace ybar::lua {

class LuaRuntime {
public:
    // messageWindow is the daemon's UI-thread mailbox (HWND); null in
    // headless tests (exec/delay then degrade to no-ops).
    LuaRuntime(ybar::model::ItemStore& store, ybar::events::EventBus& bus,
               ybar::ipc::CommandHandler& handler, ybar::app::ScriptRunner& scripts,
               void* messageWindow);
    ~LuaRuntime();

    void runConfig(const std::string& path);
    void teardown(); // bumps the generation; in-flight completions are dropped

    // Lua-first event dispatch: true when a handler consumed the event
    // (the caller then skips the shell script — spec 3.7).
    bool handleEvent(ybar::model::Item& item, const ybar::events::Environment& env);

    // UI-thread completions.
    struct ExecResult {
        int ref = 0;
        int generation = 0;
        std::string output;
        int exitCode = 0;
    };
    void completeExec(const ExecResult& result);
    bool onTimer(std::uintptr_t timerId); // true when it was a ybar.delay timer

    int generation() const { return generation_; }

    static constexpr unsigned kMsgExecDone = 0x8000 + 5; // WM_APP + 5

private:
    friend struct Trampolines;
    void registerBridge();
    void spawnExec(const std::string& command, int ref);
    void scheduleDelay(double seconds, int ref);

    ybar::model::ItemStore& store_;
    ybar::events::EventBus& bus_;
    ybar::ipc::CommandHandler& handler_;
    ybar::app::ScriptRunner& scripts_;
    void* messageWindow_;

    lua_State* state_ = nullptr;
    int generation_ = 0;
    std::map<int, std::map<std::string, int>> subscriptions_; // itemId -> event -> ref

    // Message-scoped ybar.animate context.
    std::string animateCurve_;
    int animateFrames_ = 0;
    bool animateActive_ = false;

    struct Delay {
        int ref;
        int generation;
    };
    std::map<std::uintptr_t, Delay> delays_;
    std::uintptr_t nextDelayId_ = 0x4000;
};

} // namespace ybar::lua
