#include "app/local_verbs.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// clang-format on

#include <algorithm>
#include <cstdio>
#include <filesystem>

#include "ipc/socket.h"
#include "ipc/wire_format.h"

namespace ybar::app {

namespace {

namespace fs = std::filesystem;

constexpr wchar_t kRunKey[] = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"YBar";

std::wstring widen(const std::string& text) {
    if (text.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                         static_cast<int>(text.size()), nullptr, 0);
    std::wstring wide(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()), wide.data(),
                        size);
    return wide;
}

std::string narrow(const std::wstring& wide) {
    if (wide.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(),
                                         static_cast<int>(wide.size()), nullptr, 0, nullptr,
                                         nullptr);
    std::string text(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), static_cast<int>(wide.size()), text.data(),
                        size, nullptr, nullptr);
    return text;
}

fs::path executablePath() {
    wchar_t buffer[MAX_PATH];
    const DWORD n = GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    return fs::path(std::wstring(buffer, n));
}

fs::path configDirectory() {
    wchar_t* profile = nullptr;
    std::size_t length = 0;
    if (_wdupenv_s(&profile, &length, L"USERPROFILE") != 0 || !profile) return {};
    fs::path path = fs::path(profile) / L".config" / L"ybar";
    free(profile);
    return path;
}

// A theme is any directory carrying one of the entry-point names, searched in
// the reference's order (spec 12).
std::optional<fs::path> themeEntry(const fs::path& directory) {
    for (const auto* name : {"ybarrc.lua", "ybar.jsonc", "ybarrc.jsonc"}) {
        std::error_code ec;
        const fs::path candidate = directory / name;
        if (fs::exists(candidate, ec)) return candidate;
    }
    return std::nullopt;
}

// Shipped themes sit beside the executable (installed layout) or one level up
// (running from a build tree); installed ones under ~/.config/ybar/themes.
std::vector<std::pair<std::string, fs::path>> collectThemes() {
    const fs::path exeDir = executablePath().parent_path();
    std::vector<fs::path> roots{exeDir / "examples", exeDir / "themes",
                                exeDir.parent_path() / "examples"};
    if (const fs::path config = configDirectory(); !config.empty())
        roots.push_back(config / "themes");

    std::vector<std::pair<std::string, fs::path>> themes;
    for (const auto& root : roots) {
        std::error_code ec;
        if (!fs::is_directory(root, ec)) continue;
        for (const auto& entry : fs::directory_iterator(root, ec)) {
            if (!entry.is_directory()) continue;
            const auto config = themeEntry(entry.path());
            if (!config) continue;
            const std::string name = entry.path().filename().string();
            // First root wins: a user copy shadows nothing, but a duplicate
            // name must not list twice.
            const bool seen =
                std::any_of(themes.begin(), themes.end(),
                            [&name](const auto& pair) { return pair.first == name; });
            if (!seen) themes.emplace_back(name, *config);
        }
    }
    std::sort(themes.begin(), themes.end(),
              [](const auto& a, const auto& b) { return a.first < b.first; });
    return themes;
}

fs::path currentThemeFile() {
    const fs::path config = configDirectory();
    return config.empty() ? fs::path{} : config / "current-theme";
}

int autostartStatus() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_READ, &key) != ERROR_SUCCESS) {
        std::printf("autostart: disabled\n");
        return 0;
    }
    wchar_t buffer[1024];
    DWORD size = sizeof(buffer);
    DWORD type = 0;
    const LSTATUS status =
        RegQueryValueExW(key, kRunValue, nullptr, &type, reinterpret_cast<BYTE*>(buffer), &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) {
        std::printf("autostart: disabled\n");
        return 0;
    }
    std::printf("autostart: enabled (%s)\n", narrow(std::wstring(buffer)).c_str());
    return 0;
}

int autostartEnable() {
    HKEY key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
        std::fprintf(stderr, "[!] could not open the Run key for writing\n");
        return 1;
    }
    // Quoted: the install path routinely contains spaces, and Run values are
    // parsed as command lines.
    const std::wstring command = L"\"" + executablePath().wstring() + L"\"";
    const LSTATUS status =
        RegSetValueExW(key, kRunValue, 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(command.c_str()),
                       static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
    if (status != ERROR_SUCCESS) {
        std::fprintf(stderr, "[!] could not write the Run value\n");
        return 1;
    }
    std::printf("autostart enabled: %s\n", narrow(command).c_str());
    std::printf("Toggle it later in Task Manager > Startup apps, or run "
                "`ybar autostart disable`.\n");
    return 0;
}

int autostartDisable() {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
        std::printf("autostart already disabled\n");
        return 0;
    }
    const LSTATUS status = RegDeleteValueW(key, kRunValue);
    RegCloseKey(key);
    // Absent is the desired end state, so a missing value is still success.
    if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) {
        std::fprintf(stderr, "[!] could not remove the Run value\n");
        return 1;
    }
    std::printf("autostart disabled\n");
    return 0;
}

int themeList() {
    const auto themes = collectThemes();
    if (themes.empty()) {
        std::printf("no themes found\n");
        return 0;
    }
    std::error_code ec;
    std::string active;
    if (const fs::path state = currentThemeFile();
        !state.empty() && fs::exists(state, ec)) {
        if (FILE* file = _wfopen(state.c_str(), L"rb")) {
            char buffer[256];
            const std::size_t n = std::fread(buffer, 1, sizeof(buffer) - 1, file);
            std::fclose(file);
            active.assign(buffer, n);
            while (!active.empty() && (active.back() == '\n' || active.back() == '\r'))
                active.pop_back();
        }
    }
    for (const auto& [name, config] : themes) {
        std::printf("%s %-24s %s\n", name == active ? "*" : " ", name.c_str(),
                    config.string().c_str());
    }
    return 0;
}

int themeCurrent() {
    const fs::path state = currentThemeFile();
    std::error_code ec;
    if (state.empty() || !fs::exists(state, ec)) {
        std::printf("no theme selected\n");
        return 0;
    }
    if (FILE* file = _wfopen(state.c_str(), L"rb")) {
        char buffer[256];
        const std::size_t n = std::fread(buffer, 1, sizeof(buffer) - 1, file);
        std::fclose(file);
        buffer[n] = '\0';
        std::printf("%s", buffer);
        if (n == 0 || buffer[n - 1] != '\n') std::printf("\n");
    }
    return 0;
}

int themeUse(const std::string& name, const std::string& instance) {
    const auto themes = collectThemes();
    const auto match = std::find_if(themes.begin(), themes.end(),
                                    [&name](const auto& pair) { return pair.first == name; });
    if (match == themes.end()) {
        std::fprintf(stderr, "[!] no theme named %s (try `ybar theme list`)\n", name.c_str());
        return 1;
    }

    const fs::path state = currentThemeFile();
    if (!state.empty()) {
        std::error_code ec;
        fs::create_directories(state.parent_path(), ec);
        if (FILE* file = _wfopen(state.c_str(), L"wb")) {
            std::fprintf(file, "%s\n", name.c_str());
            std::fclose(file);
        }
    }

    // A running daemon re-points at the theme's entry file; otherwise the
    // choice simply takes effect at the next start.
    const auto reply = ybar::ipc::clientSend(ybar::ipc::socketPath(instance),
                                             {"--reload", match->second.string()});
    std::printf("theme: %s%s\n", name.c_str(),
                reply ? "" : " (recorded; start ybar to apply)");
    return 0;
}

} // namespace

std::optional<int> runLocalVerb(const std::vector<std::string>& args,
                                const std::string& instance) {
    if (args.empty()) return std::nullopt;

    if (args[0] == "autostart") {
        const std::string action = args.size() > 1 ? args[1] : "status";
        if (action == "enable") return autostartEnable();
        if (action == "disable") return autostartDisable();
        if (action == "status") return autostartStatus();
        std::fprintf(stderr, "[!] usage: ybar autostart enable|disable|status\n");
        return 1;
    }

    if (args[0] == "theme") {
        const std::string action = args.size() > 1 ? args[1] : "list";
        if (action == "list") return themeList();
        if (action == "current") return themeCurrent();
        if (action == "use") {
            if (args.size() < 3) {
                std::fprintf(stderr, "[!] usage: ybar theme use <name>\n");
                return 1;
            }
            return themeUse(args[2], instance);
        }
        std::fprintf(stderr, "[!] usage: ybar theme list|current|use <name>\n");
        return 1;
    }

    return std::nullopt;
}

} // namespace ybar::app
