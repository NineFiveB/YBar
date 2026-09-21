// Small Win32 conveniences shared by the CLI verbs (spec 5, 12, 13).

#pragma once

#include <filesystem>
#include <string>

namespace ybar::app {

std::wstring widen(const std::string& utf8);
std::string narrow(const std::wstring& wide);

// The running executable, symlinks resolved: winget's portable install
// launches through a Links-directory symlink and GetModuleFileNameW reports
// the LINK path, while shipped themes, the Run value and the ybarw launcher
// all need the real location.
std::filesystem::path executablePath();

// %USERPROFILE%\.config\ybar — the reference's XDG-style config home, where
// current-theme and user themes live. Empty when USERPROFILE is unset.
std::filesystem::path configDirectory();

// %LOCALAPPDATA%\ybar — the daemon's state directory: the IPC socket that
// doubles as the instance lock, and the log a background start writes.
// Falls back to %TEMP% the same way ipc::socketPath does.
std::filesystem::path stateDirectory();

} // namespace ybar::app
