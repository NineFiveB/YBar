// app_launched / app_terminated (spec 10) without a window manager.
//
// komorebi's Show/Destroy window events are preferred when it is running
// (window-scoped, instant); this is the fallback: a 2 s process-snapshot diff
// over EnumProcesses, armed lazily on the first subscription so a config that
// never mentions these events pays nothing.
//
// Semantics differ from macOS in the documented way: this sees every process,
// including background ones with no UI, whereas the komorebi path sees only
// windows. Both publish INFO = the app display name.

#pragma once

#include <functional>
#include <string>
#include <unordered_map>

namespace ybar::providers {

class AppLifecycleProvider {
public:
    // Called on the UI thread (driven by the daemon's timer).
    std::function<void(const std::string& event, const std::string& appName)> onEvent;

    // Takes the first snapshot without publishing — otherwise arming would
    // announce every already-running process as launched.
    void prime();

    // One diff pass; call every 2 s.
    void sample();

    bool primed() const { return primed_; }

private:
    std::unordered_map<unsigned long, std::string> processes_;
    bool primed_ = false;
};

} // namespace ybar::providers
