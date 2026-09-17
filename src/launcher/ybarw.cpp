// ybarw.exe — the windowless way in (spec 5). ybar.exe is a console-subsystem
// binary because the CLI has to behave in a terminal: the shell waits for it,
// its exit code lands in $LASTEXITCODE, its output arrives before the prompt
// comes back. The price is that Explorer, the Run key and Task Scheduler hand
// a console-subsystem exe a console window before a line of its code runs.
// This GUI-subsystem stub is what they run instead: it runs `ybar.exe start
// <its own arguments>` with no window and exits with that verb's code. "w" for
// windowless, as in pythonw and javaw.
//
// It deliberately links nothing of the engine — a static CRT and the quoting
// library, a small fraction of ybar.exe — so that a launcher the login
// sequence runs on every boot has nothing in it to fail.

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <shellapi.h> // CommandLineToArgvW
// clang-format on

#include <cstdlib>
#include <string>
#include <vector>

#include "win/command_line.h"

namespace {

std::wstring siblingExecutable() {
    wchar_t buffer[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    std::wstring path(buffer, n);
    const auto slash = path.find_last_of(L"\\/");
    return (slash == std::wstring::npos ? std::wstring{} : path.substr(0, slash + 1)) +
           L"ybar.exe";
}

std::vector<std::wstring> ownArguments() {
    int count = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &count);
    std::vector<std::wstring> arguments;
    if (!argv) return arguments;
    for (int i = 1; i < count; ++i) arguments.emplace_back(argv[i]);
    LocalFree(argv);
    return arguments;
}

int report(const std::wstring& message) {
    MessageBoxW(nullptr, message.c_str(), L"ybar", MB_OK | MB_ICONERROR);
    return 1;
}

} // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    const std::wstring executable = siblingExecutable();
    if (GetFileAttributesW(executable.c_str()) == INVALID_FILE_ATTRIBUTES)
        return report(L"ybar.exe is not beside ybarw.exe:\n" + executable);

    std::vector<std::wstring> arguments{L"start"};
    for (auto& argument : ownArguments()) arguments.push_back(std::move(argument));
    std::wstring commandLine = ybar::win::buildCommandLine(executable, arguments);

    // DETACHED_PROCESS: `ybar start` is itself a console-subsystem process and
    // would otherwise be handed a console. Its stdout is of no use here; a
    // failure is reported through the exit code and the daemon's log.
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(executable.c_str(), commandLine.data(), nullptr, nullptr, FALSE,
                        DETACHED_PROCESS | CREATE_UNICODE_ENVIRONMENT, nullptr, nullptr,
                        &startup, &process)) {
        return report(L"could not run " + commandLine + L"\n(error " +
                      std::to_wstring(GetLastError()) + L")");
    }
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD exitCode = 1;
    GetExitCodeProcess(process.hProcess, &exitCode);
    CloseHandle(process.hProcess);
    if (exitCode != 0) {
        // The only moment a login-time failure is visible at all; the
        // details are in the log `ybar start` wrote.
        wchar_t* local = nullptr;
        std::size_t length = 0;
        std::wstring log = L"%LOCALAPPDATA%\\ybar\\stderr.log";
        if (_wdupenv_s(&local, &length, L"LOCALAPPDATA") == 0 && local) {
            log = std::wstring(local) + L"\\ybar\\stderr.log";
            free(local);
        }
        report(L"ybar did not start (exit " + std::to_wstring(exitCode) + L").\nSee " + log);
    }
    return static_cast<int>(exitCode);
}
