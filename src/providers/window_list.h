// Running-application list (Windows extension, spec 10.6): the taskbar
// replacement for a bar that hides the shell taskbar. This enumerates
// TOP-LEVEL WINDOWS — it is not the tray-icon capture spec 10.6 rules out
// (Explorer's tray buttons still have no per-icon API); it is the alt-tab
// list, grouped per application.
//
// Runs SYNCHRONOUSLY on the UI thread: a full pass over ~450 top-level
// windows measures in single-digit milliseconds, which is far below the IPC
// round trip that carries it, so there is no worker thread, no snapshot
// marshaling, and no same-process WM_GETTEXT deadlock to design around.

#pragma once

#include <string>
#include <vector>

namespace ybar::providers {

struct AppWindow {
    long long hwnd = 0;
    std::string title;
    bool cloaked = false; // off-screen on another workspace (informational)
};

struct AppEntry {
    std::string name;               // FileDescription, else exe stem
    std::string executablePath;     // for image = "exe.<path>"
    unsigned long processId = 0;
    std::vector<AppWindow> windows; // most-recently-active first
};

// One enumeration pass. Empty when nothing qualifies.
std::vector<AppEntry> runningApps();

// JSON for `--query windows` (same shape the Lua query trampoline expects).
std::string serializeRunningApps(const std::vector<AppEntry>& apps);

// `--window <hwnd> close|kill`.
//  close: PostMessage(WM_CLOSE) — graceful, lets the app prompt to save.
//         Posted, never sent: a hung app must not block the UI thread.
//  kill:  TerminateProcess — unconditional, no save prompt.
// Returns an empty string on success, an error message otherwise.
std::string windowAction(long long hwnd, const std::string& action);

} // namespace ybar::providers
