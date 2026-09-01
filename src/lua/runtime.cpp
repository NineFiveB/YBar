#include "lua/runtime.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"
}

#include <cstdio>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "app/script_runner.h"

namespace ybar::lua {

namespace {

LuaRuntime* g_current = nullptr; // UI-thread singleton, mirrors LuaRuntime.current

// The user-facing Lua API — byte-identical with the reference prelude
// (LuaRuntime.swift, spec 3.7). Do not edit without editing both.
//
// ONE deliberate divergence: ybar.tray(name, action), a Windows-only addition
// with no macOS counterpart — there is no notification area to act on there.
// It exists so the config does not have to shell out to the CLI to reach a
// daemon it is already running inside (see Trampolines::tray).
constexpr char kPrelude[] = R"LUA(local raw = __ybar_raw
__ybar_raw = nil

local function flatten(prefix, t, out)
  for k, v in pairs(t) do
    local key = prefix == "" and tostring(k) or (prefix .. "." .. tostring(k))
    if type(v) == "table" then
      flatten(key, v, out)
    else
      out[key] = v
    end
  end
end

local function valstr(v)
  if type(v) == "boolean" then return v and "on" or "off" end
  if type(v) == "number" then
    -- 60/2 is a FLOAT in Lua 5.4 and tostring gives "30.0", which
    -- integer-parsed properties (update_freq, max_chars...) reject.
    local i = math.tointeger(v)
    if i then return tostring(i) end
  end
  return tostring(v)
end

local function apply(fn, first, t)
  local out = {}
  flatten("", t, out)
  for k, v in pairs(out) do
    -- NOT `a and fn(...) or fn(...)`: a successful call returns nil and
    -- the or-branch would re-call with the wrong arity.
    local err
    if first then
      err = fn(first, k, valstr(v))
    else
      err = fn(k, valstr(v))
    end
    if err then print(err) end
  end
end

ybar = {}

function ybar.bar(t) apply(raw.bar, nil, t) end
function ybar.default(t) apply(raw.default, nil, t) end
function ybar.set(name, t) apply(raw.set, name, t) end
function ybar.subscribe(name, event, fn)
  if type(event) == "table" then
    for _, e in ipairs(event) do ybar.subscribe(name, e, fn) end
    return
  end
  local e = raw.subscribe(name, event, fn)
  if e then print(e) end
end
function ybar.delay(seconds, fn) raw.delay(seconds, fn) end
function ybar.update() raw.update() end
function ybar.query_table(name) return raw.query_item(name) end
function ybar.trigger(event, env) raw.trigger(event, env or {}) end
function ybar.push(name, values) raw.push(name, values) end
function ybar.exec(cmd, fn) raw.exec(cmd, fn) end
function ybar.add_event(name, notification) local e = raw.add_event(name, notification) if e then print(e) end end
function ybar.query(target) return raw.query(target) end
function ybar.tray(name, action) return raw.tray(name, action) end
function ybar.remove(name) raw.remove(name) end

function ybar.animate(curve, frames, fn)
  raw.animate_begin(curve, frames)
  local ok, err = pcall(fn)
  raw.animate_end()
  if not ok then error(err, 0) end
end

local item_methods = {}
item_methods.__index = item_methods
function item_methods:set(t) ybar.set(self.name, t) end
function item_methods:subscribe(event, fn) ybar.subscribe(self.name, event, fn) end
function item_methods:push(values) ybar.push(self.name, values) end
function item_methods:query() return raw.query_item(self.name) end

local function handle(name)
  return setmetatable({ name = name }, item_methods)
end

function ybar.add(kind, name, position, arg)
  local pos = position
  if kind == "bracket" and type(position) == "table" then
    pos = table.concat(position, ",")
  end
  if raw.add(kind, name, pos, arg) then
    local h = handle(name)
    if type(arg) == "table" then h:set(arg) end
    return h
  end
end

function ybar.item(name) return handle(name) end

package.loaded["ybar"] = ybar
)LUA";

// --- non-raising stack helpers (never luaL_check*: longjmp is UB here) ---

std::string toString(lua_State* L, int index) {
    std::size_t length = 0;
    const char* text = lua_tolstring(L, index, &length);
    return text ? std::string(text, length) : std::string();
}

// Strings and numbers only (lua_tolstring converts numbers IN PLACE — safe
// on argument slots, never on table-iteration key slots).
const char* argCString(lua_State* L, int index) {
    return lua_type(L, index) == LUA_TSTRING || lua_type(L, index) == LUA_TNUMBER
               ? lua_tolstring(L, index, nullptr)
               : nullptr;
}

void stderrLine(const std::string& line) {
    std::fprintf(stderr, "%s\n", line.c_str());
    std::fflush(stderr);
}

// Empty reply -> push nil; else push the reply (error string convention).
int pushReplyAsOptionalError(lua_State* L, const std::string& reply) {
    if (reply.empty()) lua_pushnil(L);
    else lua_pushlstring(L, reply.data(), reply.size());
    return 1;
}

std::vector<std::string> splitCommas(const std::string& text) {
    std::vector<std::string> parts;
    std::size_t start = 0;
    for (std::size_t i = 0; i <= text.size(); ++i) {
        if (i == text.size() || text[i] == ',') {
            if (i > start) parts.push_back(text.substr(start, i - start));
            start = i + 1;
        }
    }
    return parts;
}

void pushJson(lua_State* L, const nlohmann::json& value) {
    using nlohmann::json;
    switch (value.type()) {
        case json::value_t::object: {
            lua_createtable(L, 0, static_cast<int>(value.size()));
            for (const auto& [key, entry] : value.items()) {
                lua_pushlstring(L, key.data(), key.size());
                pushJson(L, entry);
                lua_settable(L, -3);
            }
            break;
        }
        case json::value_t::array: {
            lua_createtable(L, static_cast<int>(value.size()), 0);
            lua_Integer index = 1;
            for (const auto& entry : value) {
                pushJson(L, entry);
                lua_rawseti(L, -2, index++);
            }
            break;
        }
        case json::value_t::string: {
            const auto& text = value.get_ref<const std::string&>();
            lua_pushlstring(L, text.data(), text.size());
            break;
        }
        case json::value_t::boolean:
            lua_pushboolean(L, value.get<bool>() ? 1 : 0);
            break;
        case json::value_t::number_integer:
        case json::value_t::number_unsigned:
            lua_pushinteger(L, value.get<lua_Integer>());
            break;
        case json::value_t::number_float:
            lua_pushnumber(L, value.get<double>());
            break;
        default:
            lua_pushnil(L);
            break;
    }
}

} // namespace

// Trampolines get friend access through this struct.
struct Trampolines {
    static LuaRuntime& rt() { return *g_current; }

    static std::string handleTokens(std::vector<std::string> tokens) {
        return rt().handler_.handle(tokens);
    }

    // --set / --bar with the ybar.animate scope applied as a message prefix.
    static std::vector<std::string> withAnimatePrefix(std::vector<std::string> tokens) {
        if (rt().animateActive_ && rt().animateFrames_ > 0) {
            std::vector<std::string> prefixed{"--animate", rt().animateCurve_,
                                              std::to_string(rt().animateFrames_)};
            prefixed.insert(prefixed.end(), tokens.begin(), tokens.end());
            return prefixed;
        }
        return tokens;
    }

    static int bar(lua_State* L) {
        const char* key = argCString(L, 1);
        const char* value = argCString(L, 2);
        if (!key || !value) return 0;
        return pushReplyAsOptionalError(
            L, handleTokens(withAnimatePrefix({"--bar", std::string(key) + "=" + value})));
    }

    static int def(lua_State* L) {
        const char* key = argCString(L, 1);
        const char* value = argCString(L, 2);
        if (!key || !value) return 0;
        return pushReplyAsOptionalError(
            L, handleTokens({"--default", std::string(key) + "=" + value}));
    }

    static int set(lua_State* L) {
        const char* name = argCString(L, 1);
        const char* key = argCString(L, 2);
        const char* value = argCString(L, 3);
        if (!name || !key || !value) return 0;
        return pushReplyAsOptionalError(
            L, handleTokens(withAnimatePrefix(
                   {"--set", name, std::string(key) + "=" + value})));
    }

    static int add(lua_State* L) {
        const char* kind = argCString(L, 1);
        const char* name = argCString(L, 2);
        const char* position = argCString(L, 3);
        if (!kind || !name || !position) {
            lua_pushboolean(L, 0);
            stderrLine("[ybar] lua: add(kind, name, position) expects strings");
            return 1;
        }
        const bool hasWidth = lua_type(L, 4) == LUA_TNUMBER;
        const double width = hasWidth ? lua_tonumberx(L, 4, nullptr) : 0;
        std::string reply;
        const std::string kindString = kind;
        if (kindString == "item") {
            reply = handleTokens({"--add", "item", name, position});
        } else if (kindString == "graph") {
            reply = handleTokens({"--add", "graph", name, position,
                                  std::to_string(hasWidth ? static_cast<int>(width) : 60)});
        } else if (kindString == "slider") {
            reply = handleTokens({"--add", "slider", name, position,
                                  std::to_string(hasWidth ? width : 100.0)});
        } else if (kindString == "bracket") {
            std::vector<std::string> tokens{"--add", "bracket", name};
            for (auto& member : splitCommas(position)) tokens.push_back(std::move(member));
            reply = handleTokens(tokens);
        } else if (kindString == "alias") {
            reply = handleTokens({"--add", "alias", name, position});
        } else {
            reply = "[!] unknown kind: " + kindString;
        }
        lua_pushboolean(L, reply.empty() ? 1 : 0);
        if (!reply.empty()) stderrLine("[ybar] lua: " + reply);
        return 1;
    }

    static int subscribe(lua_State* L) {
        const char* name = argCString(L, 1);
        const char* event = argCString(L, 2);
        if (!name || !event || lua_type(L, 3) != LUA_TFUNCTION) {
            lua_pushstring(L, "[!] subscribe(name, event, fn) expects (string, string, function)");
            return 1;
        }
        auto* item = rt().store_.find(name);
        if (!item) {
            lua_pushstring(L, ("[!] no item named " + std::string(name)).c_str());
            return 1;
        }
        const std::string eventName = event;
        if (eventName != "routine" && eventName != "forced") {
            const auto reply = handleTokens({"--subscribe", name, eventName});
            if (!reply.empty()) {
                lua_pushlstring(L, reply.data(), reply.size());
                return 1;
            }
        }
        lua_pushvalue(L, 3);
        const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
        auto& forItem = rt().subscriptions_[item->id];
        if (const auto existing = forItem.find(eventName); existing != forItem.end())
            luaL_unref(L, LUA_REGISTRYINDEX, existing->second); // re-subscribe replaces
        forItem[eventName] = ref;
        item->hasLuaHandlers = true;
        lua_pushnil(L);
        return 1;
    }

    static int trigger(lua_State* L) {
        const char* event = argCString(L, 1);
        if (!event) {
            stderrLine("[ybar] lua: trigger(event) expects a string");
            return 0;
        }
        ybar::events::Environment extra;
        if (lua_type(L, 2) == LUA_TTABLE) {
            lua_pushnil(L);
            while (lua_next(L, 2) != 0) {
                // NEVER lua_tolstring the key slot in place: converting a
                // number key corrupts lua_next traversal. Stringify a copy.
                lua_pushvalue(L, -2);
                const std::string key = toString(L, -1);
                lua_pop(L, 1);
                const char* value = argCString(L, -1);
                if (!key.empty() && value) extra[key] = value;
                lua_pop(L, 1);
            }
        }
        if (extra.empty()) {
            handleTokens({"--trigger", event}); // forced-query interception path
            return 0;
        }
        const auto info = extra.count("INFO") ? extra.at("INFO") : std::string();
        rt().bus_.trigger(event, info, extra);
        return 0;
    }

    static int push(lua_State* L) {
        const char* name = argCString(L, 1);
        if (!name || lua_type(L, 2) != LUA_TTABLE) return 0;
        std::vector<std::string> tokens{"--push", name};
        // lua_rawlen, never luaL_len: the latter can raise through a __len
        // metamethod, and a longjmp across this C++ frame is UB (spec 3.7).
        const auto count = static_cast<lua_Integer>(lua_rawlen(L, 2));
        for (lua_Integer i = 1; i <= count; ++i) {
            lua_rawgeti(L, 2, i);
            if (lua_type(L, -1) == LUA_TNUMBER) {
                char buffer[32];
                std::snprintf(buffer, sizeof(buffer), "%g", lua_tonumberx(L, -1, nullptr));
                tokens.push_back(buffer);
            }
            lua_pop(L, 1);
        }
        const auto reply = handleTokens(tokens);
        if (!reply.empty()) stderrLine("[ybar] lua: " + reply);
        return 0;
    }

    static int animateBegin(lua_State* L) {
        const char* curve = argCString(L, 1);
        rt().animateCurve_ = curve ? curve : "linear";
        rt().animateFrames_ =
            lua_type(L, 2) == LUA_TNUMBER ? static_cast<int>(lua_tonumberx(L, 2, nullptr)) : 0;
        rt().animateActive_ = true;
        return 0;
    }

    static int animateEnd(lua_State*) {
        rt().animateActive_ = false;
        return 0;
    }

    static int update(lua_State*) {
        // Lua handlers only ("forced", falling back to "routine") — no shell
        // scripts and no provider re-queries, unlike the CLI --update.
        for (const auto& item : rt().store_.items()) {
            if (!item->hasLuaHandlers) continue;
            rt().handleEvent(*item, {{"NAME", item->name}, {"SENDER", "forced"}, {"INFO", ""}});
        }
        return 0;
    }

    static int queryItem(lua_State* L) {
        const char* name = argCString(L, 1);
        if (!name) return 0;
        const auto reply = handleTokens({"--query", name});
        if (reply.rfind("[!]", 0) == 0) {
            lua_pushnil(L);
            return 1;
        }
        try {
            pushJson(L, nlohmann::json::parse(reply));
        } catch (const nlohmann::json::exception&) {
            lua_pushnil(L);
        }
        return 1;
    }

    static int addEvent(lua_State* L) {
        const char* name = argCString(L, 1);
        if (!name) {
            lua_pushstring(L, "[!] add_event(name) expects a string");
            return 1;
        }
        const char* notification = argCString(L, 2);
        std::vector<std::string> tokens{"--add", "event", name};
        if (notification) tokens.push_back(notification);
        return pushReplyAsOptionalError(L, handleTokens(tokens));
    }

    static int query(lua_State* L) {
        const char* target = argCString(L, 1);
        if (!target) {
            lua_pushstring(L, "[!] query(target) expects a string");
            return 1;
        }
        const auto reply = handleTokens({"--query", target});
        lua_pushlstring(L, reply.data(), reply.size());
        return 1;
    }

    // Tray actions in-process. The config used to reach these by shelling out
    // to `ybar --tray ...`, which spawns cmd.exe, which spawns the CLI, which
    // opens a socket back to THIS daemon — measured at 35-55 ms per click for
    // a call the daemon can already make directly.
    //
    // It also removes the quoting problem at its root. The name is a registry
    // tooltip written by an arbitrary application; building a shell command
    // line out of it meant defending against shell metacharacters, whereas as
    // an argument it is just a string.
    static int tray(lua_State* L) {
        const char* name = argCString(L, 1);
        const char* action = argCString(L, 2);
        if (!name || !action) {
            lua_pushstring(L, "[!] tray(name, action) expects two strings");
            return 1;
        }
        return pushReplyAsOptionalError(L, handleTokens({"--tray", name, action}));
    }

    static int remove(lua_State* L) {
        const char* name = argCString(L, 1);
        if (!name) return 0;
        handleTokens({"--remove", name}); // reference silently no-ops on no match
        return 0;
    }

    static int exec(lua_State* L) {
        const char* command = argCString(L, 1);
        if (!command) return 0;
        int ref = LUA_NOREF;
        if (lua_type(L, 2) == LUA_TFUNCTION) {
            lua_pushvalue(L, 2);
            ref = luaL_ref(L, LUA_REGISTRYINDEX);
        }
        rt().spawnExec(command, ref);
        return 0;
    }

    static int delay(lua_State* L) {
        const double seconds =
            lua_type(L, 1) == LUA_TNUMBER ? lua_tonumberx(L, 1, nullptr) : 0;
        if (lua_type(L, 2) != LUA_TFUNCTION) return 0;
        lua_pushvalue(L, 2);
        const int ref = luaL_ref(L, LUA_REGISTRYINDEX);
        rt().scheduleDelay(seconds, ref);
        return 0;
    }
};

LuaRuntime::LuaRuntime(ybar::model::ItemStore& store, ybar::events::EventBus& bus,
                       ybar::ipc::CommandHandler& handler, ybar::app::ScriptRunner& scripts,
                       void* messageWindow)
    : store_(store), bus_(bus), handler_(handler), scripts_(scripts),
      messageWindow_(messageWindow) {
    g_current = this;
}

LuaRuntime::~LuaRuntime() {
    teardown();
    if (g_current == this) g_current = nullptr;
}

void LuaRuntime::teardown() {
    ++generation_; // in-flight exec/delay completions bail on mismatch
    subscriptions_.clear();
    for (const auto& [timerId, delay] : delays_) {
        (void)delay;
        if (messageWindow_) KillTimer(static_cast<HWND>(messageWindow_), timerId);
    }
    delays_.clear();
    if (state_) {
        lua_close(state_);
        state_ = nullptr;
    }
    animateActive_ = false;
}

void LuaRuntime::registerBridge() {
    lua_createtable(state_, 0, 16);
    const auto set = [this](const char* name, lua_CFunction fn) {
        lua_pushcfunction(state_, fn);
        lua_setfield(state_, -2, name);
    };
    set("bar", Trampolines::bar);
    set("default", Trampolines::def);
    set("add", Trampolines::add);
    set("set", Trampolines::set);
    set("subscribe", Trampolines::subscribe);
    set("trigger", Trampolines::trigger);
    set("push", Trampolines::push);
    set("animate_begin", Trampolines::animateBegin);
    set("animate_end", Trampolines::animateEnd);
    set("exec", Trampolines::exec);
    set("delay", Trampolines::delay);
    set("update", Trampolines::update);
    set("query_item", Trampolines::queryItem);
    set("add_event", Trampolines::addEvent);
    set("query", Trampolines::query);
    set("tray", Trampolines::tray);
    set("remove", Trampolines::remove);
    lua_setglobal(state_, "__ybar_raw");
}

void LuaRuntime::runConfig(const std::string& path) {
    teardown();
    state_ = luaL_newstate();
    luaL_openlibs(state_);
    registerBridge();

    if (luaL_loadbufferx(state_, kPrelude, sizeof(kPrelude) - 1, "=ybar-prelude", "t") != LUA_OK ||
        lua_pcall(state_, 0, 0, 0) != LUA_OK) {
        stderrLine("[!] lua prelude failed: " + toString(state_, -1));
        lua_pop(state_, 1);
        return;
    }

    // Prepend the config's directory to package.path (require() resolution).
    const auto slash = path.find_last_of("\\/");
    const std::string directory = slash == std::string::npos ? "." : path.substr(0, slash);
    lua_getglobal(state_, "package");
    lua_getfield(state_, -1, "path");
    const std::string oldPath = toString(state_, -1);
    lua_pop(state_, 1);
    const std::string newPath =
        directory + "\\?.lua;" + directory + "\\?\\init.lua;" + oldPath;
    lua_pushlstring(state_, newPath.data(), newPath.size());
    lua_setfield(state_, -2, "path");
    lua_pop(state_, 1);

    if (luaL_loadfilex(state_, path.c_str(), "t") != LUA_OK ||
        lua_pcall(state_, 0, 0, 0) != LUA_OK) {
        stderrLine("[!] lua: " + toString(state_, -1));
        lua_pop(state_, 1);
    }
}

bool LuaRuntime::handleEvent(ybar::model::Item& item, const ybar::events::Environment& env) {
    if (!state_) return false;
    const auto forItem = subscriptions_.find(item.id);
    if (forItem == subscriptions_.end()) return false;
    const auto senderIt = env.find("SENDER");
    const std::string sender = senderIt != env.end() ? senderIt->second : std::string();
    auto refIt = forItem->second.find(sender);
    if (refIt == forItem->second.end() && sender == "forced")
        refIt = forItem->second.find("routine"); // SbarLua fallback (spec 3.7)
    if (refIt == forItem->second.end()) return false;

    lua_rawgeti(state_, LUA_REGISTRYINDEX, refIt->second);
    lua_createtable(state_, 0, static_cast<int>(env.size()));
    for (const auto& [key, value] : env) {
        lua_pushlstring(state_, key.data(), key.size());
        lua_pushlstring(state_, value.data(), value.size());
        lua_settable(state_, -3);
    }
    if (lua_pcall(state_, 1, 0, 0) != LUA_OK) {
        stderrLine("[ybar] lua: event handler error: " + toString(state_, -1));
        lua_pop(state_, 1);
    }
    return true;
}

void LuaRuntime::spawnExec(const std::string& command, int ref) {
    if (!messageWindow_) { // headless tests
        if (ref != LUA_NOREF && state_) luaL_unref(state_, LUA_REGISTRYINDEX, ref);
        return;
    }
    const int generation = generation_;
    const HWND hwnd = static_cast<HWND>(messageWindow_);
    const std::wstring commandLine = scripts_.commandLineFor(command);
    const std::vector<wchar_t> environmentBlock = scripts_.environmentBlock({});

    std::thread([hwnd, generation, ref, commandLine, environmentBlock] {
        auto* result = new ExecResult{ref, generation, {}, -1};

        SECURITY_ATTRIBUTES security{sizeof(security), nullptr, TRUE};
        HANDLE readEnd = nullptr, writeEnd = nullptr;
        if (CreatePipe(&readEnd, &writeEnd, &security, 0)) {
            SetHandleInformation(readEnd, HANDLE_FLAG_INHERIT, 0);
            STARTUPINFOW startup{};
            startup.cb = sizeof(startup);
            startup.dwFlags = STARTF_USESTDHANDLES;
            startup.hStdOutput = writeEnd;
            startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
            PROCESS_INFORMATION process{};
            std::vector<wchar_t> mutableCmd(commandLine.begin(), commandLine.end());
            mutableCmd.push_back(L'\0');
            // Same PATH augmentation as shell scripts: config code calls
            // `ybar` back, which may not be on the inherited PATH.
            std::vector<wchar_t> block = environmentBlock;
            if (CreateProcessW(nullptr, mutableCmd.data(), nullptr, nullptr, TRUE,
                               CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT,
                               block.empty() ? nullptr : block.data(), nullptr, &startup,
                               &process)) {
                CloseHandle(writeEnd);
                writeEnd = nullptr;
                // Drain CONCURRENTLY with the child: reading after exit
                // deadlocks children writing > pipe capacity (spec 3.7 note).
                char buffer[4096];
                DWORD read = 0;
                while (ReadFile(readEnd, buffer, sizeof(buffer), &read, nullptr) && read > 0)
                    result->output.append(buffer, read);
                if (WaitForSingleObject(process.hProcess, 60000) == WAIT_TIMEOUT)
                    TerminateProcess(process.hProcess, 1); // 60 s watchdog
                DWORD exitCode = 0;
                GetExitCodeProcess(process.hProcess, &exitCode);
                result->exitCode = static_cast<int>(exitCode);
                CloseHandle(process.hThread);
                CloseHandle(process.hProcess);
            }
            if (writeEnd) CloseHandle(writeEnd);
            CloseHandle(readEnd);
        }
        // Strip one trailing newline (and its \r on Windows).
        if (!result->output.empty() && result->output.back() == '\n') result->output.pop_back();
        if (!result->output.empty() && result->output.back() == '\r') result->output.pop_back();
        if (!PostMessageW(hwnd, LuaRuntime::kMsgExecDone, 0,
                          reinterpret_cast<LPARAM>(result)))
            delete result;
    }).detach();
}

void LuaRuntime::completeExec(const ExecResult& result) {
    if (!state_) return;
    if (result.generation != generation_) return; // dropped across reloads
    if (result.ref == LUA_NOREF) return;
    lua_rawgeti(state_, LUA_REGISTRYINDEX, result.ref);
    luaL_unref(state_, LUA_REGISTRYINDEX, result.ref);
    lua_pushlstring(state_, result.output.data(), result.output.size());
    lua_pushinteger(state_, result.exitCode);
    if (lua_pcall(state_, 2, 0, 0) != LUA_OK) {
        stderrLine("[ybar] lua: exec callback error: " + toString(state_, -1));
        lua_pop(state_, 1);
    }
}

void LuaRuntime::scheduleDelay(double seconds, int ref) {
    if (!messageWindow_) {
        if (state_) luaL_unref(state_, LUA_REGISTRYINDEX, ref);
        return;
    }
    const std::uintptr_t timerId = nextDelayId_++;
    delays_[timerId] = {ref, generation_};
    // Clamp: a negative interval wraps UINT into a ~49-day timer.
    const double milliseconds = std::max(0.0, seconds * 1000.0);
    SetTimer(static_cast<HWND>(messageWindow_), timerId,
             static_cast<UINT>(std::min(milliseconds, 4294967294.0)), nullptr);
}

bool LuaRuntime::onTimer(std::uintptr_t timerId) {
    const auto it = delays_.find(timerId);
    if (it == delays_.end()) return false;
    if (messageWindow_) KillTimer(static_cast<HWND>(messageWindow_), timerId);
    const Delay delay = it->second;
    delays_.erase(it);
    if (!state_ || delay.generation != generation_) return true; // dropped
    lua_rawgeti(state_, LUA_REGISTRYINDEX, delay.ref);
    luaL_unref(state_, LUA_REGISTRYINDEX, delay.ref);
    if (lua_pcall(state_, 0, 0, 0) != LUA_OK) {
        stderrLine("[ybar] lua: delay callback error: " + toString(state_, -1));
        lua_pop(state_, 1);
    }
    return true;
}

} // namespace ybar::lua
