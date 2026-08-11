// Config discovery + hotload (spec section 5). Discovery order with
// <name> = instance name, .lua preferred per directory:
//   -c <path> (with ~ -> %USERPROFILE%) ->
//   %XDG_CONFIG_HOME%\<name>\<name>rc.lua|<name>rc ->
//   ~/.config/<name>/<name>rc.lua|<name>rc ->
//   ~/.<name>rc.lua | ~/.<name>rc
// Hotload: ReadDirectoryChangesW on the config DIRECTORY (sees in-place
// writes and rename-saves), 0.5 s trailing debounce + 1.0 s post-reload
// suppression window (the config run writes into the watched dir).

#pragma once

#include <atomic>
#include <functional>
#include <string>
#include <thread>

namespace ybar::app {

// Empty when no config was found. `explicitPath` may be empty.
std::string locateConfig(const std::string& instance, const std::string& explicitPath);

class Hotload {
public:
    ~Hotload();

    // onChange fires on the watcher thread — the daemon marshals to its UI
    // thread inside the callback.
    std::function<void()> onChange;

    void setEnabled(bool enabled, const std::string& configPath);
    void noteReloadHappened(); // starts the suppression window

private:
    void watchLoop();
    void stopWatcher();

    std::string directory_;
    std::thread thread_;
    std::atomic<bool> running_{false};
    std::atomic<long long> suppressUntilMs_{0};
    void* directoryHandle_ = nullptr; // HANDLE
};

} // namespace ybar::app
