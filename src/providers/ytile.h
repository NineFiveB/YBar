// YTile integration: the sibling WM adapter to KomorebiProvider, speaking
// YTile's named-pipe NDJSON protocol (YTile docs/YTILE-IPC.md). One
// persistent connection carries the subscription — the daemon pushes a
// {event, state} line per state change (full snapshot, komorebi-style).
// Work-area reservation via the `reserve <monitor> <l> <t> <r> <b>` verb,
// re-asserted on every reconnect (the protocol's `ready` contract:
// reservations do not survive a ytiled restart) and zeroed on graceful exit.
//
// Env parity with the komorebi provider: WORKSPACES carries the primary
// monitor's workspace numbers that are non-empty OR active (YTile always
// has 9 per monitor; hiding the empty ones is the macOS widget behavior the
// protocol doc itself recommends), FOCUSED_WORKSPACE is the active number,
// FOCUSED_WORKSPACE_INDEX its 1-based position in that list. Window
// manage/unmanage diffs feed app_launched/app_terminated, window-scoped
// like komorebi's Show/Destroy.

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ybar::providers {

struct YTileUpdate {
    std::string focusedWorkspace; // 1-based number string (YTile has no names)
    std::string previousWorkspace;
    // Newline-separated numbers of the shown workspaces (non-empty OR
    // active), in ascending order — the WORKSPACES env value.
    std::string workspaceNames;
    int focusedIndex = 0;        // 1-based position within workspaceNames
    int focusedMonitorIndex = 0;
    bool workspacesChanged = false;
};

class YTileProvider {
public:
    // Present = \\.\pipe\ytile exists (daemon running).
    static bool detect();

    YTileProvider();
    ~YTileProvider();

    // Called on the reader thread — the daemon posts to its UI thread.
    std::function<void(const YTileUpdate&)> onUpdate;

    // Window lifecycle from state diffs: (event name, exe). Same threading
    // contract as onUpdate. hwnd is not forwarded — by the time an unmanage
    // lands the window is usually gone, and manage's exe is authoritative.
    std::function<void(const std::string& event, const std::string& exe)> onAppEvent;

    // Connects, subscribes, fetches initial state (the stream only pushes on
    // changes), and keeps a 1s reconnect loop while ytiled restarts.
    bool start();
    void stop();

    // Work-area reservation per YTile monitor, physical pixels (top strip).
    void applyWorkAreaOffset(int barHeightPhysical);
    void clearWorkAreaOffset();

    // Forced re-query (spec 11.3 boot-population idiom).
    bool refresh();

    // Click routing without komorebi: the daemon's --komorebi passthrough
    // translates the known SocketMessage types onto these.
    bool focusListIndex(int zeroBasedListIndex); // index into WORKSPACES
    bool focusNamed(const std::string& name);    // "1".."9"
    bool cycleWorkspace(bool next);              // wraps over all 9

    // One-shot request/reply on its own connection (the server allows
    // concurrent instances). Returns false if the daemon is unreachable.
    static bool sendCommand(const std::string& cmd, const std::string& arg,
                            std::string* replyLine = nullptr);

    // Pure state-JSON -> update parse (primary monitor), exposed for the
    // contract tests. nullopt on schema mismatch.
    static std::optional<YTileUpdate> parseState(const std::string& stateJson);

private:
    void readerLoop();
    void handleState(const std::string& stateJson);

    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<std::intptr_t> pipe_{-1}; // HANDLE; closed from stop() to unblock reads
    std::atomic<int> monitorCount_{1};
    std::atomic<int> appliedOffset_{0}; // re-asserted after every reconnect
    // Reader thread and UI-thread refresh()/clicks share this state.
    std::mutex stateMutex_;
    std::string lastKey_;          // dedupe: focused + shown list
    std::string lastFocusedName_;  // plain number string, for PREV_WORKSPACE
    std::vector<int> shownNumbers_; // click translation for focusListIndex
    int lastActive_ = 0;            // 0-based, for cycleWorkspace
    std::vector<std::pair<long long, std::string>> knownWindows_; // hwnd -> exe
    bool windowsPrimed_ = false; // first snapshot primes, never announces
};

} // namespace ybar::providers
