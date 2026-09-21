#include "app/process_control.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <thread>

#include "app/config.h"
#include "app/local_verbs.h"
#include "app/platform.h"
#include "ipc/socket.h"
#include "ipc/wire_format.h"
#include "win/command_line.h"

namespace ybar::app {

namespace {

namespace fs = std::filesystem;
using namespace std::chrono_literals;
using Clock = std::chrono::steady_clock;

// A cold Lua config can take a while to answer its first --ping; the
// reference waits 30 s behind launchd's throttle, we have no throttle.
constexpr auto kReadyTimeout = 20s;
constexpr auto kNoticeAfter = 3s;
constexpr auto kStopTimeout = 10s;
constexpr auto kPoll = 250ms;
// Nothing rotates what a login start captures, and one failing Lua callback
// writes a line per tick into this file forever. Two files of about a
// megabyte is the cheapest bound that needs no daemon.
constexpr std::uintmax_t kLogLimit = 1024 * 1024;

int fail(const std::string& message) {
    std::fprintf(stderr, "[!] %s\n", message.c_str());
    return 1;
}

int usage(const std::string& invocation) {
    std::fprintf(stderr, "[!] usage: %s\n", invocation.c_str());
    return 2;
}

std::string field(const std::string& name, const std::string& value) {
    return "  " + name + std::string(name.size() < 10 ? 11 - name.size() : 1, ' ') + value;
}

bool ping(const std::string& socketPath) {
    const auto reply = ybar::ipc::clientSend(socketPath, {"--ping"}, 1.0);
    return reply && *reply == "pong";
}

// `~` -> %USERPROFILE%, then absolute and normalized: the daemon is launched
// with no working directory of ours, so a relative -c has to be resolved
// here or it points somewhere else in the child.
std::string absolutePath(const std::string& path) {
    std::wstring wide = widen(path);
    if (!wide.empty() && wide[0] == L'~') {
        wchar_t* profile = nullptr;
        std::size_t length = 0;
        if (_wdupenv_s(&profile, &length, L"USERPROFILE") == 0 && profile) {
            wide = std::wstring(profile) + wide.substr(1);
            free(profile);
        }
    }
    std::error_code ec;
    const fs::path absolute = fs::absolute(fs::path(wide), ec);
    return narrow((ec ? fs::path(wide) : absolute).lexically_normal().wstring());
}

struct StartOutcome {
    int code = 0;
    std::vector<std::string> lines; // stdout on success
    std::string error;              // the [!] line on failure
};

void rotateLog(const fs::path& log) {
    std::error_code ec;
    const auto size = fs::file_size(log, ec);
    if (ec || size <= kLogLimit) return;
    fs::path rolled = log;
    rolled += L".1";
    fs::remove(rolled, ec);
    fs::rename(log, rolled, ec);
}

std::string logTail(const fs::path& log, std::uintmax_t fromOffset, std::size_t maxLines) {
    FILE* file = _wfopen(log.c_str(), L"rb");
    if (!file) return {};
    std::string text;
    if (_fseeki64(file, static_cast<long long>(fromOffset), SEEK_SET) == 0) {
        char buffer[4096];
        std::size_t n = 0;
        while ((n = std::fread(buffer, 1, sizeof(buffer), file)) > 0) text.append(buffer, n);
    }
    std::fclose(file);
    while (!text.empty() && (text.back() == '\n' || text.back() == '\r')) text.pop_back();
    std::size_t start = text.size();
    std::size_t lines = 0;
    while (start > 0) {
        if (text[start - 1] == '\n' && ++lines == maxLines) break;
        --start;
    }
    return text.substr(start);
}

HANDLE openInheritable(const std::wstring& path, DWORD access, DWORD disposition) {
    SECURITY_ATTRIBUTES inheritable{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    return CreateFileW(path.c_str(), access, FILE_SHARE_READ | FILE_SHARE_WRITE, &inheritable,
                       disposition, FILE_ATTRIBUTE_NORMAL, nullptr);
}

// The daemon as a detached process: no console at all (DETACHED_PROCESS, so
// Explorer's and the Run key's console can close, and a terminal's prompt
// comes straight back), stdin/stdout on NUL, stderr appended to the log.
std::optional<DWORD> launchDetached(const fs::path& executable,
                                    const std::vector<std::wstring>& arguments, HANDLE log,
                                    std::string& error) {
    HANDLE nul = openInheritable(L"NUL", GENERIC_READ | GENERIC_WRITE, OPEN_EXISTING);
    if (nul == INVALID_HANDLE_VALUE) {
        error = "could not open NUL";
        return std::nullopt;
    }

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESTDHANDLES;
    startup.hStdInput = nul;
    startup.hStdOutput = nul;
    startup.hStdError = log;

    std::wstring commandLine = ybar::win::buildCommandLine(executable.wstring(), arguments);
    PROCESS_INFORMATION process{};
    // Breakaway first: a terminal or scheduler that put us in a
    // kill-on-close job would otherwise take the bar down with this client.
    // A job that forbids breakaway answers ERROR_ACCESS_DENIED; retry inside.
    DWORD flags = DETACHED_PROCESS | CREATE_UNICODE_ENVIRONMENT | CREATE_BREAKAWAY_FROM_JOB;
    BOOL created = CreateProcessW(executable.c_str(), commandLine.data(), nullptr, nullptr, TRUE,
                                  flags, nullptr, nullptr, &startup, &process);
    if (!created && GetLastError() == ERROR_ACCESS_DENIED) {
        flags &= ~static_cast<DWORD>(CREATE_BREAKAWAY_FROM_JOB);
        created = CreateProcessW(executable.c_str(), commandLine.data(), nullptr, nullptr, TRUE,
                                 flags, nullptr, nullptr, &startup, &process);
    }
    const DWORD lastError = GetLastError();
    CloseHandle(nul);
    if (!created) {
        error = "could not launch " + narrow(executable.wstring()) + " (error " +
                std::to_string(lastError) + ")";
        return std::nullopt;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return process.dwProcessId;
}

StartOutcome startDaemon(const std::string& configOverride, const std::string& instance) {
    StartOutcome outcome;
    const std::string socketPath = ybar::ipc::socketPath(instance);

    std::string config;
    if (!configOverride.empty()) {
        config = absolutePath(configOverride);
        if (!configFileExists(config)) {
            outcome.code = 1;
            outcome.error = "config not found: " + config;
            return outcome;
        }
    }

    // isListening, not ping: a bar that is mid-config-run cannot answer a
    // --ping for seconds, and reading that as "not running" would launch a
    // second instance to lose the socket race noisily.
    if (ybar::ipc::isListening(socketPath)) {
        outcome.lines.push_back(instance + " is already running");
        if (!config.empty())
            outcome.lines.push_back("  (`" + instance + " restart -c " + configOverride +
                                    "` switches a running bar to another config)");
        return outcome;
    }

    const fs::path log = daemonLogPath();
    std::error_code ec;
    fs::create_directories(log.parent_path(), ec);
    rotateLog(log);
    const std::uintmax_t logOffset = fs::exists(log, ec) ? fs::file_size(log, ec) : 0;
    HANDLE logHandle =
        openInheritable(log.wstring(), FILE_APPEND_DATA | SYNCHRONIZE, OPEN_ALWAYS);
    if (logHandle == INVALID_HANDLE_VALUE) {
        outcome.code = 1;
        outcome.error = "could not open " + narrow(log.wstring()) + " for the bar's stderr";
        return outcome;
    }
    {
        char stamp[32] = {};
        const std::time_t now = std::time(nullptr);
        std::tm local{};
        localtime_s(&local, &now);
        std::strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &local);
        const std::string header = "--- " + instance + " start " + stamp + " ---\n";
        DWORD written = 0;
        WriteFile(logHandle, header.data(), static_cast<DWORD>(header.size()), &written,
                  nullptr);
    }

    std::vector<std::wstring> arguments;
    if (!config.empty()) arguments = {L"-c", widen(config)};
    const fs::path executable = executablePath();
    const auto pid = launchDetached(executable, arguments, logHandle, outcome.error);
    CloseHandle(logHandle);
    if (!pid) {
        outcome.code = 1;
        return outcome;
    }

    // Readiness, not existence: "answers commands" is exactly what is being
    // waited for, so this is the one place --ping is the right question.
    HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, *pid);
    const auto started = Clock::now();
    bool noticed = false;
    bool ready = false;
    std::optional<DWORD> exitCode;
    while (Clock::now() - started < kReadyTimeout) {
        if (ping(socketPath)) {
            ready = true;
            break;
        }
        if (process && WaitForSingleObject(process, 0) == WAIT_OBJECT_0) {
            DWORD code = 0;
            GetExitCodeProcess(process, &code);
            exitCode = code;
            break;
        }
        if (!noticed && Clock::now() - started >= kNoticeAfter) {
            noticed = true;
            // stderr, so a script capturing stdout is unaffected.
            std::fputs("still waiting for the bar to come up...\n", stderr);
        }
        std::this_thread::sleep_for(kPoll);
    }
    if (process) CloseHandle(process);

    const std::string logPath = narrow(log.wstring());
    if (!ready) {
        outcome.code = 1;
        if (exitCode) {
            outcome.error = instance + " exited with code " + std::to_string(*exitCode) +
                            " before answering — see " + logPath;
        } else {
            outcome.error = instance + " was launched (pid " + std::to_string(*pid) +
                            ") but did not answer within " +
                            std::to_string(std::chrono::seconds(kReadyTimeout).count()) +
                            " s — see " + logPath;
        }
        if (const std::string tail = logTail(log, logOffset, 8); !tail.empty())
            outcome.error += "\n" + tail;
        return outcome;
    }

    outcome.lines.push_back(instance + " started (pid " + std::to_string(*pid) + ")");
    if (!config.empty()) outcome.lines.push_back(field("config", config));
    outcome.lines.push_back(field("log", logPath));
    return outcome;
}

void printAutostartNote(const std::string& instance, bool wasRunning) {
    if (!autostartRunValue()) return;
    std::printf("%s (`%s autostart disable` to turn that off)\n",
                wasRunning ? "autostart is enabled — it will start again at your next login"
                           : "it starts again at your next login",
                instance.c_str());
}

int stopDaemon(const std::string& instance, bool quietWhenNotRunning) {
    const std::string socketPath = ybar::ipc::socketPath(instance);
    if (!ybar::ipc::isListening(socketPath)) {
        if (!quietWhenNotRunning) {
            std::printf("%s is not running\n", instance.c_str());
            printAutostartNote(instance, false);
        }
        return 0;
    }

    // The daemon replies and then tears itself down, so a failure to read the
    // reply is not a failure to stop.
    ybar::ipc::clientSend(socketPath, {"--exit"}, 2.0);

    // The socket FILE, not a connect: a daemon that exits deletes its
    // endpoint, and every probe connect parks a connection on the listener's
    // backlog until it is accepted. One connect at the deadline still catches
    // a daemon that died without cleaning up. GetFileAttributes, not
    // fs::exists: an AF_UNIX socket file is a reparse point, which the
    // filesystem library tries to follow and reports as not found — that
    // answered "gone" instantly for a bar that was still tearing down.
    const std::wstring socketFile = widen(socketPath);
    const auto deadline = Clock::now() + kStopTimeout;
    bool gone = false;
    while (Clock::now() < deadline) {
        if (GetFileAttributesW(socketFile.c_str()) == INVALID_FILE_ATTRIBUTES) {
            gone = true;
            break;
        }
        std::this_thread::sleep_for(kPoll);
    }
    if (!gone && ybar::ipc::isListening(socketPath)) {
        // Deliberately no escalation to TerminateProcess: there is no pid
        // here, and killing by image name is the `Stop-Process ybar` bug this
        // verb exists to replace.
        return fail(instance + " did not exit within " +
                    std::to_string(std::chrono::seconds(kStopTimeout).count()) + " s — " +
                    socketPath + " still answers");
    }
    std::printf("%s stopped\n", instance.c_str());
    printAutostartNote(instance, true);
    return 0;
}

int runStart(const std::string& configOverride, const std::string& instance) {
    const StartOutcome outcome = startDaemon(configOverride, instance);
    for (const auto& line : outcome.lines) std::printf("%s\n", line.c_str());
    if (outcome.code != 0) return fail(outcome.error);
    return 0;
}

int runRestart(const std::string& configOverride, const std::string& instance) {
    if (const int stopped = stopDaemon(instance, true); stopped != 0) return stopped;
    return runStart(configOverride, instance);
}

int runStatus(const std::string& instance) {
    const std::string socketPath = ybar::ipc::socketPath(instance);
    const bool running = ybar::ipc::isListening(socketPath);
    const fs::path executable = executablePath();
    const std::string config = locateConfig(instance, "");
    // Label the path with the theme only when the theme is what produced it:
    // the recorded name can be stale, in which case discovery fell through.
    std::string theme;
    if (instance == "ybar" && !config.empty() && config == themeConfigFromCurrentTheme())
        theme = currentThemeName();
    const auto autostart = autostartRunValue();

    std::printf("%s\n", field(instance, running ? "running" : "not running").c_str());
    std::printf("%s\n", field("instance", instance).c_str());
    std::printf("%s\n", field("socket", socketPath).c_str());
    std::printf("%s\n", field("exe", narrow(executable.wstring())).c_str());
    std::string configLine = config.empty() ? "none found" : config;
    if (!theme.empty()) configLine += " (theme: " + theme + ")";
    std::printf("%s\n", field("config", configLine).c_str());
    std::printf("%s\n", field("autostart",
                              autostart ? "enabled (" + narrow(*autostart) + ")" : "disabled")
                            .c_str());
    std::printf("%s\n", field("log", narrow(daemonLogPath().wstring())).c_str());

    // `config` is what a fresh start would pick. The daemon does not report
    // its own config over the wire yet, so a running bar may be on another.
    if (running)
        std::printf("note: `config` is what a fresh start would pick; "
                    "a running bar may have been started with -c.\n");
    if (config.empty())
        std::printf("note: no config found; the bar will come up empty. See README.md.\n");
    std::error_code ec;
    if (!fs::exists(launcherPath(executable), ec))
        std::printf("note: ybarw.exe is not beside %s — a login start or a double-click "
                    "will flash a console window.\n",
                    narrow(executable.filename().wstring()).c_str());
    return 0;
}

} // namespace

ConfigArgument parseConfigArgument(const std::vector<std::string>& rest) {
    if (rest.empty()) return {ConfigArgument::Kind::Absent, {}};
    if (rest.size() == 2 && (rest[0] == "-c" || rest[0] == "--config"))
        return {ConfigArgument::Kind::Path, rest[1]};
    return {ConfigArgument::Kind::Malformed, {}};
}

std::optional<ProcessVerb> parseProcessVerb(const std::vector<std::string>& args) {
    if (args.empty()) return std::nullopt;
    const std::string& verb = args[0];
    const std::vector<std::string> rest(args.begin() + 1, args.end());

    const auto withConfig = [&](ProcessVerb::Kind kind) -> ProcessVerb {
        const ConfigArgument config = parseConfigArgument(rest);
        if (config.kind == ConfigArgument::Kind::Malformed)
            return {ProcessVerb::Kind::Usage, {}, verb + " [-c <path>]"};
        return {kind, config.path, {}};
    };
    const auto bare = [&](ProcessVerb::Kind kind) -> ProcessVerb {
        if (!rest.empty()) return {ProcessVerb::Kind::Usage, {}, verb};
        return {kind, {}, {}};
    };

    if (verb == "start") return withConfig(ProcessVerb::Kind::Start);
    if (verb == "restart") return withConfig(ProcessVerb::Kind::Restart);
    if (verb == "stop") return bare(ProcessVerb::Kind::Stop);
    if (verb == "status") return bare(ProcessVerb::Kind::Status);
    return std::nullopt;
}

bool shouldDetachFromConsole(unsigned long consoleProcessCount, bool debugRequested) {
    return consoleProcessCount == 1 && !debugRequested;
}

unsigned long consoleProcessCount() {
    DWORD pid = 0;
    // The count is returned even when the buffer is too small for the list.
    return GetConsoleProcessList(&pid, 1);
}

fs::path launcherPath(const fs::path& executable) {
    return executable.parent_path() / L"ybarw.exe";
}

std::wstring autostartCommand(const fs::path& executable, bool launcherPresent) {
    if (launcherPresent)
        return ybar::win::buildCommandLine(launcherPath(executable).wstring(), {});
    return ybar::win::buildCommandLine(executable.wstring(), {L"start"});
}

fs::path daemonLogPath() { return stateDirectory() / L"stderr.log"; }

int runProcessVerb(const ProcessVerb& verb, const std::string& instance) {
    switch (verb.kind) {
    case ProcessVerb::Kind::Usage: return usage(instance + " " + verb.usage);
    case ProcessVerb::Kind::Start: return runStart(verb.config, instance);
    case ProcessVerb::Kind::Stop: return stopDaemon(instance, false);
    case ProcessVerb::Kind::Restart: return runRestart(verb.config, instance);
    case ProcessVerb::Kind::Status: return runStatus(instance);
    }
    return usage(instance + " start|stop|restart|status");
}

int detachFromConsole(const std::string& instance, const std::string& configPath) {
    const StartOutcome outcome = startDaemon(configPath, instance);
    if (outcome.code != 0) {
        MessageBoxW(nullptr, widen(outcome.error).c_str(), widen(instance).c_str(),
                    MB_OK | MB_ICONERROR);
    }
    return outcome.code;
}

} // namespace ybar::app
