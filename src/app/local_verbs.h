// Local CLI verbs that never reach the daemon socket (spec 5, 12, 13):
//
//   ybar start [-c <path>] | stop | restart [-c <path>] | status
//   ybar autostart enable|disable|status
//   ybar theme list|current|use <name>|reset
//
// The macOS side ships the theme verbs as a POSIX `ybar-theme` script and
// autostart as a LaunchAgent plist; on Windows the natural homes are an HKCU
// Run value and a subcommand of the one binary we distribute. Exit codes
// follow the reference: 0 success, 1 the operation failed, 2 the invocation
// was wrong.

#pragma once

#include <optional>
#include <string>
#include <vector>

namespace ybar::app {

// Returns the process exit code when `args` names a local verb, nullopt when
// the caller should keep dispatching.
std::optional<int> runLocalVerb(const std::vector<std::string>& args,
                                const std::string& instance);

// The name in ~/.config/ybar/current-theme (written by `ybar theme use`),
// or "" when unset.
std::string currentThemeName();

// Resolves ~/.config/ybar/current-theme to the theme's entry config path, or
// "" when unset/unresolvable. Config discovery consults this so a chosen
// theme survives daemon restarts.
std::string themeConfigFromCurrentTheme();

// The HKCU Run value `autostart enable` wrote, or nullopt when autostart is
// off. A non-string value (another writer's) reads as an empty string.
std::optional<std::wstring> autostartRunValue();

} // namespace ybar::app
