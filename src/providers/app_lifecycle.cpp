#include "providers/app_lifecycle.h"

#include "providers/app_info.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <tlhelp32.h>
// clang-format on

#include <unordered_map>
#include <vector>

namespace ybar::providers {

namespace {

// Toolhelp rather than EnumProcesses: one call yields pid + exe name, so the
// common "nothing changed" pass never opens a single process handle.
std::unordered_map<unsigned long, std::string> snapshot() {
    std::unordered_map<unsigned long, std::string> processes;
    const HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return processes;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snap, &entry)) {
        do {
            const int size = WideCharToMultiByte(CP_UTF8, 0, entry.szExeFile, -1, nullptr, 0,
                                                 nullptr, nullptr);
            std::string exe(static_cast<std::size_t>(size - 1), '\0');
            WideCharToMultiByte(CP_UTF8, 0, entry.szExeFile, -1, exe.data(), size, nullptr,
                                nullptr);
            processes.emplace(entry.th32ProcessID, std::move(exe));
        } while (Process32NextW(snap, &entry));
    }
    CloseHandle(snap);
    return processes;
}

} // namespace

void AppLifecycleProvider::prime() {
    processes_ = snapshot();
    primed_ = true;
}

void AppLifecycleProvider::sample() {
    auto current = snapshot();
    if (current.empty()) return; // snapshot failed; keep the old baseline
    if (!primed_) {
        processes_ = std::move(current);
        primed_ = true;
        return;
    }

    for (const auto& [pid, exe] : current) {
        if (processes_.count(pid)) continue;
        // The friendly name needs the full image path, so resolve only for
        // the handful of pids that actually appeared.
        std::string name = appNameForProcess(pid);
        if (name.empty()) name = appNameForExecutablePath(exe);
        if (!name.empty() && onEvent) onEvent("app_launched", name);
    }
    for (const auto& [pid, exe] : processes_) {
        if (current.count(pid)) continue;
        // The process is gone — only the cached exe name remains.
        const std::string name = appNameForExecutablePath(exe);
        if (!name.empty() && onEvent) onEvent("app_terminated", name);
    }
    processes_ = std::move(current);
}

} // namespace ybar::providers
