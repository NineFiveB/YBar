// YTile integration: the sibling WM adapter to KomorebiProvider, speaking
// YTile's named-pipe NDJSON protocol (YTile docs/YTILE-IPC.md). One
// persistent connection carries the subscription — the daemon pushes a
// {event, state} line per state change (full snapshot, komorebi-style).
// Work-area reservation via the `reserve <monitor> <l> <t> <r> <b>` verb,
// zeroed on graceful exit.

#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>

namespace ybar::providers {

struct YTileUpdate {
    std::string focusedWorkspace; // 1-based index string (YTile has no names)
    std::string previousWorkspace;
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

    // Connects, subscribes, fetches initial state (the stream only pushes on
    // changes), and keeps a 1s reconnect loop while ytiled restarts.
    bool start();
    void stop();

    // Work-area reservation per YTile monitor, physical pixels (top strip).
    void applyWorkAreaOffset(int barHeightPhysical);
    void clearWorkAreaOffset();

    // One-shot request/reply on its own connection (the server allows
    // concurrent instances). Returns false if the daemon is unreachable.
    static bool sendCommand(const std::string& cmd, const std::string& arg,
                            std::string* replyLine = nullptr);

private:
    void readerLoop();
    void handleState(const std::string& stateJson);

    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<std::intptr_t> pipe_{-1}; // HANDLE; closed from stop() to unblock reads
    std::string lastFocused_;
    int monitorCount_ = 1;
};

} // namespace ybar::providers
