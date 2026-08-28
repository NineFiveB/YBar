// komorebi integration (spec section 11): subscription over the socket
// protocol verified against v0.1.41 — subscriber creates a listener in
// komorebi's data dir, registers via AddSubscriberSocketWithOptions, and
// receives one full-State JSON per connection (read to EOF). Work-area
// reservation via MonitorWorkAreaOffset ({left:0,top:H,right:0,bottom:H} —
// bottom is a HEIGHT reduction), zeroed on graceful exit.

#pragma once

#include <atomic>
#include <cstdint>
#include <mutex>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

namespace ybar::providers {

struct KomorebiUpdate {
    std::string focusedWorkspace; // name when set, else 1-based index string
    std::string previousWorkspace;
    // Newline-separated display names of the focused monitor's workspaces,
    // in komorebi order — what a workspaces widget builds its pills from
    // (published as WORKSPACES; spec 11.3 allows enriching the env).
    std::string workspaceNames;
    int focusedIndex = 0;        // 1-based position within workspaceNames
    int focusedMonitorIndex = 0; // komorebi's monitor index
    bool workspacesChanged = false;
};

class KomorebiProvider {
public:
    // Present = komorebi.sock exists in %LOCALAPPDATA%\komorebi.
    static bool detect();

    KomorebiProvider();
    ~KomorebiProvider();

    // Marshaled delivery: called on the reader thread — the daemon posts to
    // its UI thread inside this callback.
    std::function<void(const KomorebiUpdate&)> onUpdate;

    // Window lifecycle from Show/Destroy notifications: (event name, exe,
    // hwnd — 0 when komorebi did not include one). Same threading contract
    // as onUpdate. The hwnd lets the daemon resolve the real process name
    // instead of trusting a bare exe basename.
    std::function<void(const std::string& event, const std::string& exe, std::uintptr_t hwnd)>
        onAppEvent;

    // Starts the subscription (listener + registration + reconnect loop).
    // subscriberName becomes the socket file name in komorebi's data dir.
    bool start(const std::string& subscriberName);
    void stop();

    // Work-area reservation handshake. barHeightPhysical includes y_offset,
    // in physical pixels (spec 11.4). Applied to every komorebi monitor.
    void applyWorkAreaOffset(int barHeightPhysical);
    void clearWorkAreaOffset();

    // Send one raw SocketMessage JSON to komorebi (click commands, --komorebi).
    static bool sendMessage(const std::string& json);

    // Re-queries komorebi and publishes an update (forced-query path for
    // `ybar --trigger komorebi_workspace_change`, spec 11.3).
    bool refresh();

    // Pure notification/State JSON -> update parse (focused monitor),
    // exposed for the contract tests. Accepts a full {event, state}
    // notification or a bare State reply; nullopt on schema mismatch.
    // workspacesChanged=false marks a snapshot whose focused indices are
    // out of range — publishState drops those without publishing.
    static std::optional<KomorebiUpdate> parseNotification(const std::string& payload);

private:
    void readerLoop();
    void reregister();
    void publishState(const std::string& notificationOrState);

    std::string subscriberPath_;
    std::string subscriberName_;
    std::uintptr_t listenSocket_ = ~0ull;
    std::thread thread_;
    std::atomic<bool> running_{false};
    // publishState runs on the reader thread AND (via refresh) the UI
    // thread; the dedupe string needs a real lock, the scalars get atomics.
    std::mutex stateMutex_; // guards lastFocused_ / lastFocusedName_
    std::string lastFocused_;     // composite dedupe key
    std::string lastFocusedName_; // plain name, for PREV_WORKSPACE
    std::atomic<int> monitorCount_{1};
    std::atomic<bool> monitorCountKnown_{false};
    std::atomic<int> appliedOffset_{0};
};

} // namespace ybar::providers
