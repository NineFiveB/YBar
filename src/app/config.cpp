#include "app/config.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <cstdio>
#include <cstdlib>
#include <vector>

namespace ybar::app {

namespace {

bool fileExists(const std::string& path) {
    const DWORD attributes = GetFileAttributesA(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES &&
           !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

std::string home() {
    const char* profile = std::getenv("USERPROFILE");
    return profile ? profile : "";
}

std::string expandTilde(const std::string& path) {
    if (!path.empty() && path[0] == '~')
        return home() + path.substr(1);
    return path;
}

long long nowMs() { return static_cast<long long>(GetTickCount64()); }

} // namespace

std::string locateConfig(const std::string& instance, const std::string& explicitPath) {
    if (!explicitPath.empty()) {
        const auto expanded = expandTilde(explicitPath);
        if (fileExists(expanded)) return expanded;
        std::fprintf(stderr, "[!] config not found: %s\n", explicitPath.c_str());
        return {}; // daemon runs configless (reference behavior)
    }
    const std::string rcLua = instance + "rc.lua";
    const std::string rc = instance + "rc";
    std::vector<std::string> directories;
    if (const char* xdg = std::getenv("XDG_CONFIG_HOME"))
        directories.push_back(std::string(xdg) + "\\" + instance);
    directories.push_back(home() + "\\.config\\" + instance);
    for (const auto& directory : directories) {
        if (fileExists(directory + "\\" + rcLua)) return directory + "\\" + rcLua;
        if (fileExists(directory + "\\" + rc)) return directory + "\\" + rc;
        // JSONC entries are first-class on ybar-win (Lua runtime pending).
        if (fileExists(directory + "\\" + instance + "rc.jsonc"))
            return directory + "\\" + instance + "rc.jsonc";
        if (fileExists(directory + "\\" + instance + ".jsonc"))
            return directory + "\\" + instance + ".jsonc";
    }
    if (fileExists(home() + "\\." + rcLua)) return home() + "\\." + rcLua;
    if (fileExists(home() + "\\." + rc)) return home() + "\\." + rc;
    return {};
}

Hotload::~Hotload() { stopWatcher(); }

void Hotload::setEnabled(bool enabled, const std::string& configPath) {
    stopWatcher();
    if (!enabled || configPath.empty()) return;
    const auto slash = configPath.find_last_of("\\/");
    directory_ = slash == std::string::npos ? "." : configPath.substr(0, slash);
    directoryHandle_ =
        CreateFileA(directory_.c_str(), FILE_LIST_DIRECTORY,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                    OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (directoryHandle_ == INVALID_HANDLE_VALUE) {
        directoryHandle_ = nullptr;
        return;
    }
    running_ = true;
    thread_ = std::thread([this] { watchLoop(); });
}

void Hotload::noteReloadHappened() { suppressUntilMs_ = nowMs() + 1000; }

void Hotload::stopWatcher() {
    if (!running_.exchange(false)) return;
    if (directoryHandle_) CancelIoEx(directoryHandle_, nullptr);
    if (thread_.joinable()) thread_.join();
    if (directoryHandle_) CloseHandle(directoryHandle_);
    directoryHandle_ = nullptr;
}

void Hotload::watchLoop() {
    alignas(DWORD) char buffer[8192];
    while (running_) {
        DWORD bytes = 0;
        const BOOL ok = ReadDirectoryChangesW(
            directoryHandle_, buffer, sizeof(buffer), FALSE,
            FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_FILE_NAME, &bytes, nullptr,
            nullptr);
        if (!ok || !running_) break;
        if (nowMs() < suppressUntilMs_) continue; // post-reload suppression

        // Trailing-edge debounce: absorb the save burst, then fire once.
        Sleep(500);
        // Drain queued notifications quickly (non-blocking would need OVERLAPPED;
        // the suppression window covers reload-triggered writes).
        if (nowMs() < suppressUntilMs_) continue;
        if (onChange) onChange();
    }
}

} // namespace ybar::app
