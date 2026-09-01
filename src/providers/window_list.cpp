#include "providers/window_list.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dwmapi.h>
#include <propsys.h>
#include <shlobj.h>
// clang-format on

#include <algorithm>
#include <unordered_map>

#include <nlohmann/json.hpp>

#include "providers/app_info.h"

namespace ybar::providers {

namespace {

std::string narrow(const std::wstring& wide) {
    if (wide.empty()) return {};
    const int size = WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()),
                                         nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<std::size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide.data(), static_cast<int>(wide.size()), out.data(), size,
                        nullptr, nullptr);
    return out;
}

std::wstring windowText(HWND hwnd) {
    // GetWindowTextLengthW/GetWindowTextW on a FOREIGN window is
    // non-blocking by design (the caller never waits on a hung app). It is
    // only a WM_GETTEXT send for windows owned by THIS process, which the
    // caller filters out before reaching here.
    const int length = GetWindowTextLengthW(hwnd);
    if (length <= 0) return {};
    std::wstring text(static_cast<std::size_t>(length) + 1, L'\0');
    const int copied = GetWindowTextW(hwnd, text.data(), length + 1);
    text.resize(copied > 0 ? static_cast<std::size_t>(copied) : 0);
    return text;
}

std::wstring className(HWND hwnd) {
    wchar_t buffer[256] = L"";
    const int copied = GetClassNameW(hwnd, buffer, 256);
    return std::wstring(buffer, copied > 0 ? static_cast<std::size_t>(copied) : 0);
}

bool cloaked(HWND hwnd) {
    DWORD value = 0;
    // Informational only. The cloak bit must NOT filter: with a tiling WM
    // every window parked on another workspace reads DWM_CLOAKED_SHELL while
    // being a perfectly real running app (measured: Chrome, Warp, Notepad).
    return SUCCEEDED(DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &value, sizeof(value))) &&
           value != 0;
}

// Raymond Chen's alt-tab rule: follow the owner chain to the window the
// shell would actually show.
bool isRootOwner(HWND hwnd) {
    HWND walk = GetAncestor(hwnd, GA_ROOTOWNER);
    for (;;) {
        HWND attempt = GetLastActivePopup(walk);
        if (attempt == walk) break;
        if (IsWindowVisible(attempt)) {
            walk = attempt;
            break;
        }
        walk = attempt;
    }
    return walk == hwnd;
}

// A suspended/ghost UWP frame has no AppUserModelID; a live one does. This
// replaces the intuitive "does the frame host a foreign-pid child" test,
// which is WRONG on current Windows 11 builds — the CoreWindow is not
// reparented into the frame, so a live app's frame has only same-pid
// children and the child test would drop a running app.
bool hasAppUserModelId(HWND hwnd) {
    // Defined locally rather than pulled from propkey.h so the build does not
    // need propsys.lib for one constant.
    static const PROPERTYKEY kAppUserModelId = {
        {0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}}, 5};
    IPropertyStore* store = nullptr;
    if (FAILED(SHGetPropertyStoreForWindow(hwnd, IID_PPV_ARGS(&store))) || !store) return false;
    PROPVARIANT value;
    PropVariantInit(&value);
    bool present = false;
    if (SUCCEEDED(store->GetValue(kAppUserModelId, &value)))
        present = value.vt == VT_LPWSTR && value.pwszVal && value.pwszVal[0] != L'\0';
    PropVariantClear(&value);
    store->Release();
    return present;
}

std::string executablePath(DWORD processId) {
    const HANDLE process =
        OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, processId);
    if (!process) return {};
    wchar_t buffer[MAX_PATH * 2] = L"";
    DWORD size = MAX_PATH * 2;
    std::string path;
    if (QueryFullProcessImageNameW(process, 0, buffer, &size))
        path = narrow(std::wstring(buffer, size));
    CloseHandle(process);
    return path;
}

struct Collector {
    std::vector<AppEntry> apps;
    std::unordered_map<std::string, std::size_t> byPath; // lowercased exe path
    DWORD selfPid = GetCurrentProcessId();
};

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

BOOL CALLBACK enumProc(HWND hwnd, LPARAM param) {
    auto* collector = reinterpret_cast<Collector*>(param);

    // 0. Never touch our own windows: GetWindowText on a same-process window
    // is a WM_GETTEXT send, which would re-enter the message pump we are
    // being called from.
    DWORD processId = 0;
    GetWindowThreadProcessId(hwnd, &processId);
    if (processId == 0 || processId == collector->selfPid) return TRUE;

    // 1. Titled windows only — kills ghost frames and ~300 helper windows.
    const std::wstring title = windowText(hwnd);
    if (title.empty()) return TRUE;

    // 2. The desktop itself.
    if (hwnd == GetShellWindow()) return TRUE;

    // 3. A UWP app's CoreWindow is its own top-level window on current
    // builds; the ApplicationFrameWindow is the one the shell lists.
    const std::wstring cls = className(hwnd);
    if (cls == L"Windows.UI.Core.CoreWindow") return TRUE;

    // 4/5/6. Shell listing rules: no children, no pure tool windows
    // (WS_EX_APPWINDOW overrides WS_EX_TOOLWINDOW — Raycast sets both), no
    // owned windows.
    const LONG style = GetWindowLongW(hwnd, GWL_STYLE);
    if (style & WS_CHILD) return TRUE;
    const LONG exStyle = GetWindowLongW(hwnd, GWL_EXSTYLE);
    if ((exStyle & WS_EX_TOOLWINDOW) && !(exStyle & WS_EX_APPWINDOW)) return TRUE;
    if (GetWindow(hwnd, GW_OWNER) != nullptr) return TRUE;

    // 7. Load-bearing: without it the list explodes with hidden helper
    // windows (nvcontainer, ArmouryCrate, ...). Cost: apps minimized fully
    // to the tray are not listed — the real taskbar behaves the same way.
    if (!IsWindowVisible(hwnd)) return TRUE;

    // 8. Owner-chain root only.
    if (!isRootOwner(hwnd)) return TRUE;

    // 10. Live-UWP test (see hasAppUserModelId).
    if (cls == L"ApplicationFrameWindow" && !hasAppUserModelId(hwnd)) return TRUE;

    std::string path = executablePath(processId);
    std::string name = appNameForWindow(hwnd);
    if (name.empty()) name = appNameForProcess(processId);
    if (name.empty() && !path.empty()) name = appNameForExecutablePath(path);
    if (name.empty()) return TRUE;

    // Group per application. Windows with no readable path (access denied)
    // group by display name instead so they still collapse sensibly.
    const std::string key = lower(path.empty() ? name : path);
    auto found = collector->byPath.find(key);
    if (found == collector->byPath.end()) {
        AppEntry entry;
        entry.name = name;
        entry.executablePath = path;
        entry.processId = processId;
        found = collector->byPath.emplace(key, collector->apps.size()).first;
        collector->apps.push_back(std::move(entry));
    }
    AppWindow window;
    window.hwnd = reinterpret_cast<long long>(hwnd);
    window.title = narrow(title);
    window.cloaked = cloaked(hwnd);
    collector->apps[found->second].windows.push_back(std::move(window));
    return TRUE;
}

} // namespace

std::vector<AppEntry> runningApps() {
    Collector collector;
    EnumWindows(&enumProc, reinterpret_cast<LPARAM>(&collector));
    // Alphabetical: EnumWindows returns approximate z-order, which makes rows
    // jump under the pointer between refreshes.
    std::sort(collector.apps.begin(), collector.apps.end(),
              [](const AppEntry& a, const AppEntry& b) { return lower(a.name) < lower(b.name); });
    return collector.apps;
}

std::string serializeRunningApps(const std::vector<AppEntry>& apps) {
    nlohmann::json out = nlohmann::json::array();
    for (const auto& app : apps) {
        nlohmann::json windows = nlohmann::json::array();
        for (const auto& window : app.windows) {
            windows.push_back({{"hwnd", window.hwnd},
                               {"title", window.title},
                               {"cloaked", window.cloaked}});
        }
        out.push_back({{"name", app.name},
                       {"executable", app.executablePath},
                       {"pid", static_cast<std::uint64_t>(app.processId)},
                       {"window_count", app.windows.size()},
                       {"windows", windows}});
    }
    return out.dump(2);
}

std::string windowAction(long long hwnd, const std::string& action) {
    auto* target = reinterpret_cast<HWND>(hwnd);
    if (!IsWindow(target)) return "[!] no such window";
    if (action == "close") {
        // Posted, not sent: a modal/hung app must not stall the bar.
        return PostMessageW(target, WM_CLOSE, 0, 0) ? std::string{}
                                                    : "[!] close was refused";
    }
    if (action == "kill") {
        DWORD processId = 0;
        GetWindowThreadProcessId(target, &processId);
        if (!processId) return "[!] no process for window";
        const HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, processId);
        if (!process) return "[!] cannot open process (elevated?)";
        const BOOL ok = TerminateProcess(process, 1);
        CloseHandle(process);
        return ok ? std::string{} : "[!] terminate was refused (elevated?)";
    }
    return "[!] unknown window action: " + action;
}

} // namespace ybar::providers
