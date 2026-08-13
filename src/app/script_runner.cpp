#include "app/script_runner.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <cstdlib>
#include <thread>
#include <vector>

namespace ybar::app {

namespace {

std::wstring widen(const std::string& utf8) {
    if (utf8.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring wide(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), wide.data(),
                        size);
    return wide;
}

// CommandLineToArgvW-compatible argument quoting.
std::wstring quoteArg(const std::wstring& arg) {
    if (!arg.empty() && arg.find_first_of(L" \t\"") == std::wstring::npos) return arg;
    std::wstring quoted = L"\"";
    std::size_t backslashes = 0;
    for (const wchar_t c : arg) {
        if (c == L'\\') {
            ++backslashes;
        } else if (c == L'"') {
            quoted.append(backslashes * 2 + 1, L'\\');
            quoted.push_back(L'"');
            backslashes = 0;
        } else {
            quoted.append(backslashes, L'\\');
            quoted.push_back(c);
            backslashes = 0;
        }
    }
    quoted.append(backslashes * 2, L'\\');
    quoted.push_back(L'"');
    return quoted;
}

std::wstring findOnPath(const wchar_t* name) {
    wchar_t buffer[MAX_PATH];
    if (SearchPathW(nullptr, name, nullptr, MAX_PATH, buffer, nullptr) > 0) return buffer;
    return {};
}

// Git for Windows does not put its sh.exe on the Windows PATH, yet themes
// (the flagship included) write sh-style commands — single-quote quoting
// and tr/awk pipelines — that the powershell fallback cannot parse. Git's
// sh does NOT add its own /usr/bin to PATH for `sh -c` (that only happens
// in login shells), so environmentBlock also prepends the shell's
// directory — usr\bin, where the coreutils those pipelines call live.
std::wstring gitShFromRegistry() {
    for (const HKEY root : {HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE}) {
        wchar_t buffer[MAX_PATH];
        DWORD size = sizeof(buffer);
        if (RegGetValueW(root, L"SOFTWARE\\GitForWindows", L"InstallPath", RRF_RT_REG_SZ,
                         nullptr, buffer, &size) != ERROR_SUCCESS)
            continue;
        const std::wstring candidate = std::wstring(buffer) + L"\\usr\\bin\\sh.exe";
        if (GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) return candidate;
    }
    return {};
}

std::wstring exeDirectory() {
    wchar_t buffer[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    std::wstring path(buffer, n);
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? L"." : path.substr(0, slash);
}

} // namespace

ScriptRunner::ScriptRunner() {
    if (const char* custom = std::getenv("YBAR_SHELL")) {
        shell_ = widen(custom);
        posix_ = shell_.find(L"powershell") == std::wstring::npos &&
                 shell_.find(L"pwsh") == std::wstring::npos &&
                 shell_.find(L"cmd") == std::wstring::npos;
        return;
    }
    if (auto sh = findOnPath(L"sh.exe"); !sh.empty()) {
        shell_ = std::move(sh);
        posix_ = true;
        return;
    }
    if (auto sh = gitShFromRegistry(); !sh.empty()) {
        shell_ = std::move(sh);
        posix_ = true;
        return;
    }
    shell_ = findOnPath(L"powershell.exe");
    if (shell_.empty()) shell_ = L"powershell.exe";
    posix_ = false;
}

std::wstring ScriptRunner::commandLineFor(const std::string& script) const {
    std::wstring commandLine = quoteArg(shell_);
    if (posix_) {
        commandLine += L" -c " + quoteArg(widen(script));
    } else {
        commandLine += L" -NoProfile -Command " + quoteArg(widen(script));
    }
    return commandLine;
}

void ScriptRunner::run(const std::string& script, const std::map<std::string, std::string>& env) {
    if (script.empty()) return;
    spawn(commandLineFor(script), env);
}

void ScriptRunner::runFile(const std::string& path,
                           const std::map<std::string, std::string>& env) {
    std::wstring commandLine = quoteArg(shell_);
    if (posix_) {
        // exec-"$0" trick: the path travels as an argv word, immune to quoting.
        commandLine += L" -c " + quoteArg(L"exec \"$0\"") + L" " + quoteArg(widen(path));
    } else {
        commandLine += L" -NoProfile -Command " + quoteArg(L"& \"" + widen(path) + L"\"");
    }
    spawn(commandLine, env);
}

namespace {

// Environment variable names are case-insensitive on Windows, and the
// parent's spelling varies by launcher (Explorer/pwsh pass `Path`, MSYS
// shells pass `PATH`). A case-sensitive merge would duplicate the key —
// and the PATH prepend below would then miss the real entry, leaving
// children with PATH=<exe dir> only. CreateProcessW also requires the
// block sorted case-insensitively, which this comparator provides.
struct EnvKeyLess {
    bool operator()(const std::wstring& a, const std::wstring& b) const {
        return CompareStringOrdinal(a.c_str(), static_cast<int>(a.size()), b.c_str(),
                                    static_cast<int>(b.size()),
                                    TRUE) == CSTR_LESS_THAN;
    }
};

} // namespace

std::vector<wchar_t> ScriptRunner::environmentBlock(
    const std::map<std::string, std::string>& env) const {
    // Parent env overlaid with base + event vars; PATH gets the ybar.exe
    // directory prepended so scripts can call `ybar` back.
    std::map<std::wstring, std::wstring, EnvKeyLess> merged;
    if (LPWCH parent = GetEnvironmentStringsW()) {
        for (LPWCH cursor = parent; *cursor;) {
            const std::wstring entry(cursor);
            cursor += entry.size() + 1;
            const auto eq = entry.find(L'=');
            if (eq != std::wstring::npos && eq > 0)
                merged[entry.substr(0, eq)] = entry.substr(eq + 1);
        }
        FreeEnvironmentStringsW(parent);
    }
    for (const auto& [key, value] : baseEnvironment) merged[widen(key)] = widen(value);
    for (const auto& [key, value] : env) merged[widen(key)] = widen(value);
    // Scripts call `ybar` back, and Git-sh scripts call coreutils that live
    // beside a registry-resolved sh.exe — neither directory is on a normal
    // parent PATH.
    std::wstring prefix = exeDirectory();
    if (const auto slash = shell_.find_last_of(L"\\/"); slash != std::wstring::npos)
        prefix += L";" + shell_.substr(0, slash);
    if (auto it = merged.find(L"PATH"); it != merged.end())
        it->second = prefix + L";" + it->second;
    else
        merged[L"PATH"] = prefix;

    std::vector<wchar_t> block;
    for (const auto& [key, value] : merged) {
        const std::wstring entry = key + L"=" + value;
        block.insert(block.end(), entry.begin(), entry.end());
        block.push_back(L'\0');
    }
    block.push_back(L'\0');
    return block;
}

void ScriptRunner::spawn(const std::wstring& commandLine,
                         const std::map<std::string, std::string>& env) {
    std::vector<wchar_t> block = environmentBlock(env);

    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    std::vector<wchar_t> mutableCmd(commandLine.begin(), commandLine.end());
    mutableCmd.push_back(L'\0');
    const std::wstring cwd = widen(workingDirectory);
    if (CreateProcessW(nullptr, mutableCmd.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | CREATE_SUSPENDED,
                       block.data(), cwd.empty() ? nullptr : cwd.c_str(), &startup,
                       &process)) {
        // Job object: the 60 s watchdog kills the whole tree, fixing the
        // latent "children of the shell survive" gap the spec calls out.
        if (const HANDLE job = CreateJobObjectW(nullptr, nullptr)) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits,
                                    sizeof(limits));
            AssignProcessToJobObject(job, process.hProcess);
            ResumeThread(process.hThread);
            CloseHandle(process.hThread);
            // Watchdog thread owns both handles; closing the job handle after
            // the wait terminates any survivor (fire-and-forget otherwise).
            std::thread([job, handle = process.hProcess] {
                WaitForSingleObject(handle, 60000);
                CloseHandle(job); // KILL_ON_JOB_CLOSE reaps stragglers
                CloseHandle(handle);
            }).detach();
        } else {
            ResumeThread(process.hThread);
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
        }
    }
}

} // namespace ybar::app
