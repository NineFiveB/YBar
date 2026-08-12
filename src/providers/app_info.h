// Application display names (spec 10): the Windows stand-in for
// NSRunningApplication.localizedName.
//
// Resolution order per process: the executable's FileDescription version
// string, else the file name without ".exe". UWP apps hosted by
// ApplicationFrameHost.exe are unwrapped to the real app process, so the bar
// shows "Mail" rather than "ApplicationFrameHost".

#pragma once

#include <string>

namespace ybar::providers {

// Display name for a process id ("" when the process is gone/inaccessible).
std::string appNameForProcess(unsigned long processId);

// Display name for a top-level window, unwrapping the UWP frame host.
std::string appNameForWindow(void* hwnd);

// exe basename minus ".exe" — komorebi reports `exe`, not a friendly name,
// so its window events route through here for the same display string.
std::string appNameForExecutablePath(const std::string& path);

} // namespace ybar::providers
