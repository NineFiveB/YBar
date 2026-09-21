// Process control — `ybar start|stop|restart|status` (spec 5). These manage
// the daemon rather than talk to it, so they are answered before anything is
// put on the wire, and their exit codes follow the reference's contract:
// 0 success (every idempotent no-op included), 1 the operation failed, 2 the
// invocation was wrong. Parsing is kept apart from doing so the argv tests can
// cover every spelling without being one typo away from launching a bar.

#pragma once

#include <filesystem>
#include <optional>
#include <string>
#include <vector>

namespace ybar::app {

// `-c <path>` / `--config <path>` after a verb. Anything else — an extra
// word, a bare `-c` — is Malformed, so a typo is refused with a usage line
// instead of silently ignored.
struct ConfigArgument {
    enum class Kind { Absent, Path, Malformed };
    Kind kind = Kind::Absent;
    std::string path;
    bool operator==(const ConfigArgument&) const = default;
};
ConfigArgument parseConfigArgument(const std::vector<std::string>& rest);

struct ProcessVerb {
    enum class Kind { Start, Stop, Restart, Status, Usage };
    Kind kind = Kind::Status;
    std::string config; // Start/Restart: the -c value, "" for config discovery
    std::string usage;  // Usage: the invocation to print after the instance name
    bool operator==(const ProcessVerb&) const = default;
};

// Pure: what these arguments mean, or nullopt when they are not a
// process-control verb and the caller should keep dispatching.
std::optional<ProcessVerb> parseProcessVerb(const std::vector<std::string>& args);

// A console holding exactly one process was created FOR that process —
// Explorer, the Run key, a scheduler — and would sit on the desktop for as
// long as the bar runs. A shell's console (two or more) is left alone: `ybar`
// in a terminal runs in that terminal. YBAR_DEBUG keeps even an owned console,
// since it exists to watch the trace.
bool shouldDetachFromConsole(unsigned long consoleProcessCount, bool debugRequested);

// GetConsoleProcessList, or 0 when this process has no console at all.
unsigned long consoleProcessCount();

// The sibling GUI-subsystem launcher: `ybarw.exe` beside `ybar.exe`.
std::filesystem::path launcherPath(const std::filesystem::path& executable);

// The Run value `autostart enable` writes: the launcher when it is there,
// else `"<exe>" start`, which works but opens (and closes) a console.
std::wstring autostartCommand(const std::filesystem::path& executable, bool launcherPresent);

// %LOCALAPPDATA%\ybar\stderr.log — the same file scripts/install.ps1 points a
// started bar at. Only stderr is captured: the daemon's diagnostics go there,
// and a failure at login is otherwise completely invisible.
std::filesystem::path daemonLogPath();

int runProcessVerb(const ProcessVerb& verb, const std::string& instance);

// Daemon side: hand this invocation to a detached copy of the executable and
// exit, so the console this process was given can close. A failure is shown
// in a message box — the console is about to vanish, so stderr is no use.
int detachFromConsole(const std::string& instance, const std::string& configPath);

} // namespace ybar::app
