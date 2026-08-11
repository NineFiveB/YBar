// komorebi integration (spec section 11): subscription over the socket
// protocol verified against v0.1.41 — subscriber creates a listener in
// komorebi's data dir, registers via AddSubscriberSocketWithOptions, and
// receives one full-State JSON per connection (read to EOF). Work-area
// reservation via MonitorWorkAreaOffset ({left:0,top:H,right:0,bottom:H} —
// bottom is a HEIGHT reduction), zeroed on graceful exit.

#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace ybar::providers {

struct KomorebiUpdate {
    std::string focusedWorkspace; // name when set, else 1-based index string
    std::string previousWorkspace;
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

private:
    void readerLoop();

    std::string subscriberPath_;
    std::string subscriberName_;
    std::uintptr_t listenSocket_ = ~0ull;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::string lastFocused_;
    int monitorCount_ = 1;
};

} // namespace ybar::providers
