// Local CLI verbs that never reach the daemon socket (spec 12, 13):
//
//   ybar autostart enable|disable|status
//   ybar theme list|current|use <name>
//
// The macOS side ships these as a POSIX `ybar-theme` script and a LaunchAgent
// plist; on Windows the natural homes are an HKCU Run value and a subcommand
// of the one binary we distribute.

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace ybar::app {

// Returns the process exit code when `args` names a local verb, nullopt when
// the caller should keep dispatching.
std::optional<int> runLocalVerb(const std::vector<std::string>& args,
                                const std::string& instance);

} // namespace ybar::app
