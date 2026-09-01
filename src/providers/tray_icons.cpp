#include "providers/tray_icons.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
// UIAutomationCore.h builds on IAccessible and the OLE types, both of which
// WIN32_LEAN_AND_MEAN excludes — without these it fails to parse its own
// forward declarations (C2146 on IRawElementProviderSimple).
#include <ole2.h>
#include <oleacc.h>
#include <uiautomation.h>
// LEAN_AND_MEAN drops shellapi.h (ShellExecuteW) and winver.h
// (GetFileVersionInfoW), and shlobj.h does not put either back — name both.
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <winver.h>
// clang-format on

#include <algorithm>
#include <cctype>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <iterator>
#include <map>
#include <set>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

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

std::wstring widen(const std::string& narrowText) {
    if (narrowText.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, narrowText.data(),
                                         static_cast<int>(narrowText.size()), nullptr, 0);
    std::wstring out(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, narrowText.data(), static_cast<int>(narrowText.size()),
                        out.data(), size);
    return out;
}

std::wstring lower(std::wstring text) {
    std::transform(text.begin(), text.end(), text.begin(),
                   [](wchar_t c) { return static_cast<wchar_t>(towlower(c)); });
    return text;
}

std::wstring baseName(const std::wstring& path) {
    const auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

// ── Registry: the registration list ───────────────────────────────────────
std::wstring regString(HKEY key, const wchar_t* name) {
    DWORD size = 0;
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, nullptr, &size) != ERROR_SUCCESS)
        return {};
    std::wstring value(size / sizeof(wchar_t), L'\0');
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, value.data(), &size) !=
        ERROR_SUCCESS)
        return {};
    value.resize(std::wcslen(value.c_str())); // drop the trailing NUL RegGetValue counts
    return value;
}

bool regFlag(HKEY key, const wchar_t* name) {
    DWORD value = 0;
    DWORD size = sizeof(value);
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_DWORD, nullptr, &value, &size) !=
        ERROR_SUCCESS)
        return false;
    return value != 0;
}

// ExecutablePath is stored relative to a known folder as "{GUID}\rest" for
// anything under Program Files or WindowsApps.
std::wstring resolvePath(const std::wstring& raw) {
    if (raw.empty() || raw.front() != L'{') return raw;
    const auto close = raw.find(L'}');
    if (close == std::wstring::npos) return raw;
    GUID folder{};
    if (FAILED(IIDFromString(raw.substr(0, close + 1).c_str(), &folder))) return {};
    PWSTR base = nullptr;
    if (FAILED(SHGetKnownFolderPath(folder, KF_FLAG_DEFAULT, nullptr, &base)) || !base) return {};
    std::wstring out = base;
    CoTaskMemFree(base);
    std::wstring rest = raw.substr(close + 1);
    if (!rest.empty() && rest.front() != L'\\') out += L'\\';
    out += rest;
    return out;
}

std::string fileDescription(const std::wstring& path) {
    DWORD ignored = 0;
    const DWORD size = GetFileVersionInfoSizeW(path.c_str(), &ignored);
    if (!size) return {};
    std::vector<std::byte> buffer(size);
    if (!GetFileVersionInfoW(path.c_str(), 0, size, buffer.data())) return {};

    struct Translation {
        WORD language;
        WORD codePage;
    };
    Translation* translations = nullptr;
    UINT bytes = 0;
    if (!VerQueryValueW(buffer.data(), L"\\VarFileInfo\\Translation",
                        reinterpret_cast<void**>(&translations), &bytes) ||
        bytes < sizeof(Translation))
        return {};

    for (UINT i = 0; i < bytes / sizeof(Translation); ++i) {
        wchar_t query[64];
        swprintf_s(query, L"\\StringFileInfo\\%04x%04x\\FileDescription", translations[i].language,
                   translations[i].codePage);
        wchar_t* text = nullptr;
        UINT length = 0;
        if (VerQueryValueW(buffer.data(), query, reinterpret_cast<void**>(&text), &length) && text &&
            length)
            return narrow(std::wstring(text, wcsnlen(text, length)));
    }
    return {};
}

std::vector<std::byte> regBinary(HKEY key, const wchar_t* name) {
    DWORD size = 0;
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_BINARY, nullptr, nullptr, &size) !=
            ERROR_SUCCESS ||
        size == 0)
        return {};
    std::vector<std::byte> blob(size);
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_BINARY, nullptr, blob.data(), &size) !=
        ERROR_SUCCESS)
        return {};
    blob.resize(size);
    return blob;
}

// IconSnapshot is a literal PNG, so the renderer can load it straight off disk
// (GlyphAtlas::image decodes a bare file-path source through WIC).
//
// The file is named after a hash of its own CONTENT, which is load-bearing in
// three ways. The atlas caches by the source string alone and never restats the
// file, so an icon that changed under a stable name would render the old pixels
// forever; content addressing gives changed pixels a new path. It also sidesteps
// naming entirely — labels carry colons, U+2024 and other characters Windows
// forbids in filenames — and it deduplicates apps that share an icon.
std::string cacheIconPng(const std::vector<std::byte>& blob) {
    static constexpr std::byte kPngMagic[] = {std::byte{0x89}, std::byte{0x50}, std::byte{0x4E},
                                              std::byte{0x47}};
    if (blob.size() < sizeof(kPngMagic) ||
        !std::equal(std::begin(kPngMagic), std::end(kPngMagic), blob.begin()))
        return {};

    std::uint64_t hash = 1469598103934665603ull; // FNV-1a
    for (const std::byte b : blob) {
        hash ^= static_cast<std::uint8_t>(b);
        hash *= 1099511628211ull;
    }

    PWSTR localAppData = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, KF_FLAG_DEFAULT, nullptr,
                                    &localAppData)) ||
        !localAppData)
        return {};
    std::wstring directory = localAppData;
    CoTaskMemFree(localAppData);
    directory += L"\\ybar\\tray";
    // Alongside the daemon's socket; SHCreateDirectoryExW makes intermediates.
    const int made = SHCreateDirectoryExW(nullptr, directory.c_str(), nullptr);
    if (made != ERROR_SUCCESS && made != ERROR_ALREADY_EXISTS && made != ERROR_FILE_EXISTS)
        return {};

    wchar_t leaf[32];
    swprintf_s(leaf, L"\\%016llx.png", static_cast<unsigned long long>(hash));
    const std::wstring path = directory + leaf;

    // Write-once, and deliberately never swept. A cleanup pass keyed on which
    // apps are running would delete roughly half these files on any given popup
    // open (14 of 29 registrations were live when measured) and regenerate them
    // later — which destroys the deduplication, puts FindFirstFileW/DeleteFileW
    // on the click-to-open path, and above all opens an absence window that
    // content addressing makes PERMANENT: GlyphAtlas caches a failed load as
    // nullopt under the source string and never erases it, so a regenerated
    // file reuses the poisoned key and that row stays blank forever. If growth
    // ever needs bounding, sweep by age ONCE at startup before any atlas
    // exists, never by liveness.
    //
    // Growth is slow anyway: a new file appears only when an icon's bytes
    // actually change. The matching cost is a color-atlas rect per distinct
    // icon (the shelf packer has no eviction either), which the 1024x1024 page
    // absorbs a few hundred times over before it warns and skips.
    //
    // Identical content means an identical name, so an existing file is already
    // byte-for-byte what we would write.
    if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        const HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                        CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) return {};
        DWORD written = 0;
        const bool ok = WriteFile(file, blob.data(), static_cast<DWORD>(blob.size()), &written,
                                  nullptr) &&
                        written == blob.size();
        CloseHandle(file);
        if (!ok) {
            DeleteFileW(path.c_str()); // never leave a truncated PNG behind
            return {};
        }
    }
    return narrow(path);
}

std::vector<DWORD> processesForImage(const std::wstring& leafLower) {
    std::vector<DWORD> pids;
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return pids;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            if (lower(entry.szExeFile) == leafLower) pids.push_back(entry.th32ProcessID);
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return pids;
}

BOOL CALLBACK postCloseToOwned(HWND hwnd, LPARAM param) {
    DWORD owner = 0;
    GetWindowThreadProcessId(hwnd, &owner);
    // Post, never Send: a hung app would otherwise block the caller for the
    // full SendMessage timeout.
    if (owner == static_cast<DWORD>(param)) PostMessageW(hwnd, WM_CLOSE, 0, 0);
    return TRUE;
}

struct VisibleWindowSearch {
    DWORD pid;
    bool found;
};

BOOL CALLBACK findVisibleWindow(HWND hwnd, LPARAM param) {
    auto* search = reinterpret_cast<VisibleWindowSearch*>(param);
    DWORD owner = 0;
    GetWindowThreadProcessId(hwnd, &owner);
    if (owner == search->pid && IsWindowVisible(hwnd)) {
        search->found = true;
        return FALSE;
    }
    return TRUE;
}

// A process still showing a window after being asked to close is talking to
// the user — an unsaved-changes prompt, most likely. One with no visible
// window took the request and hid to the tray instead, which is the case this
// verb exists to defeat. Only the latter gets terminated.
bool hasVisibleWindow(DWORD pid) {
    VisibleWindowSearch search{pid, false};
    EnumWindows(findVisibleWindow, reinterpret_cast<LPARAM>(&search));
    return search.found;
}

std::wstring imagePathOf(HANDLE process) {
    wchar_t buffer[MAX_PATH * 2];
    DWORD size = static_cast<DWORD>(std::size(buffer));
    if (!QueryFullProcessImageNameW(process, 0, buffer, &size)) return {};
    return std::wstring(buffer, size);
}

// A PID plus a handle opened at request time. The handle is what makes the
// delayed terminate safe: it pins the kernel object, so the PID cannot be
// recycled onto an unrelated process during the grace period and be killed in
// its place.
struct CloseTarget {
    HANDLE handle;
    DWORD pid;
};

struct MainWindowSearch {
    DWORD pid;
    HWND iconic;  // minimised: unambiguously the app, put away by the user
    HWND visible; // already on screen: just needs raising
};

BOOL CALLBACK findMainWindow(HWND hwnd, LPARAM param) {
    auto* search = reinterpret_cast<MainWindowSearch*>(param);
    DWORD owner = 0;
    GetWindowThreadProcessId(hwnd, &owner);
    if (owner != search->pid) return TRUE;
    if (GetWindow(hwnd, GW_OWNER)) return TRUE;       // an owned dialog, not the app
    if (GetWindowTextLengthW(hwnd) == 0) return TRUE; // message-only/helper windows
    if (IsIconic(hwnd)) {
        if (!search->iconic) search->iconic = hwnd;
    } else if (IsWindowVisible(hwnd)) {
        if (!search->visible) search->visible = hwnd;
    }
    return TRUE; // keep scanning: rank the candidates, do not take the first
}

// Un-minimises the app, or raises it if it is already up.
//
// Deliberately does NOT show a window that is merely HIDDEN. A titled hidden
// window is usually not the thing the user wants to see: OneDrive keeps a
// "GDI+ Window (OneDrive.exe)", SecurityHealthSystray and Radeon Software each
// keep their own, and showing one of those pops an internal window the app
// took care to hide. An app in that state gets left to the ShellExecute path,
// where its own single-instance handling decides what to surface.
bool restoreWindowOf(DWORD pid) {
    MainWindowSearch search{pid, nullptr, nullptr};
    EnumWindows(findMainWindow, reinterpret_cast<LPARAM>(&search));
    HWND target = search.iconic ? search.iconic : search.visible;
    if (!target) return false;
    if (IsIconic(target)) ShowWindow(target, SW_RESTORE);
    // Best-effort: the foreground right is refused unless the caller owns it,
    // and the window is un-minimised either way, which is the part that counts.
    SetForegroundWindow(target);
    return true;
}

// PIDs whose FULL image path matches, so an invoke cannot act on an unrelated
// program that merely shares an executable name — the same rule the close path
// enforces, for the same reason. Only query rights are taken here; the close
// path deliberately opens its own handles with the terminate right instead of
// reusing these, so that a PID cannot be recycled between check and kill.
std::vector<DWORD> verifiedPids(const std::wstring& leafLower,
                                const std::wstring& wantedPathLower) {
    std::vector<DWORD> pids;
    for (const DWORD pid : processesForImage(leafLower)) {
        const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!process) continue;
        const bool matches = lower(imagePathOf(process)) == wantedPathLower;
        CloseHandle(process);
        if (matches) pids.push_back(pid);
    }
    return pids;
}

// What is running, described as precisely as the process will allow.
//
// Full paths are the real answer, but not every process yields one: NVIDIA's
// tray icon belongs to NVDisplay.Container.exe running as SYSTEM, which a
// normal process cannot open at all. Those degrade to a bare executable name,
// which is why both sets exist.
struct LiveImages {
    std::set<std::wstring> paths;     // lowercased, for processes we could read
    std::set<std::wstring> basenames; // lowercased, for processes we could not
};

LiveImages liveImages() {
    LiveImages live;
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return live;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            const HANDLE process =
                OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, entry.th32ProcessID);
            std::wstring path;
            if (process) {
                path = lower(imagePathOf(process));
                CloseHandle(process);
            }
            if (path.empty())
                live.basenames.insert(lower(entry.szExeFile));
            else
                live.paths.insert(std::move(path));
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return live;
}

// A registration counts as live when its exact executable is running, or when
// something by that NAME is running whose path we were not allowed to read.
//
// The exact test is what stops phantom rows: this machine registers a tray
// icon for the packaged Claude desktop app under Program Files, and separately
// runs Claude Code CLI from AppData. Name-only matching called the desktop app
// "running" on the strength of the CLI, listing a row for an app that was not
// there — and worse, pointing it at unrelated processes.
bool isLive(const LiveImages& live, const std::wstring& fullPathLower,
            const std::wstring& leafLower) {
    return live.paths.count(fullPathLower) > 0 || live.basenames.count(leafLower) > 0;
}

// ── UIA: activation only ──────────────────────────────────────────────────
struct AutomationSession {
    IUIAutomation* automation = nullptr;
    bool ownsCom = false;

    AutomationSession() {
        // The UI thread is already an STA with COM live; a second init on the
        // same apartment is a refcount bump, and RPC_E_CHANGED_MODE means
        // someone else owns the apartment, which is fine to borrow.
        const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        ownsCom = SUCCEEDED(hr);
        CoCreateInstance(CLSID_CUIAutomation, nullptr, CLSCTX_INPROC_SERVER,
                         IID_PPV_ARGS(&automation));
    }
    ~AutomationSession() {
        if (automation) automation->Release();
        if (ownsCom) CoUninitialize();
    }
};

// Tray elements hang off this bridge child, NOT off Shell_TrayWnd itself: with
// the taskbar hidden, ElementFromHandle(Shell_TrayWnd) yields a childless Pane.
HWND bridgeChild(HWND host) {
    if (!host) return nullptr;
    return FindWindowExW(host, nullptr, L"Windows.UI.Composition.DesktopWindowContentBridge",
                         nullptr);
}

// Collects the reachable NotifyItemIcon elements and their labels.
void collectElements(IUIAutomation* automation, HWND host, std::vector<std::string>& names,
                     std::vector<IUIAutomationElement*>& elements) {
    HWND bridge = bridgeChild(host);
    if (!bridge) return;
    IUIAutomationElement* root = nullptr;
    if (FAILED(automation->ElementFromHandle(bridge, &root)) || !root) return;

    VARIANT want;
    VariantInit(&want);
    want.vt = VT_BSTR;
    want.bstrVal = SysAllocString(L"NotifyItemIcon");
    IUIAutomationCondition* condition = nullptr;
    if (SUCCEEDED(automation->CreatePropertyCondition(UIA_AutomationIdPropertyId, want,
                                                      &condition)) &&
        condition) {
        IUIAutomationElementArray* found = nullptr;
        if (SUCCEEDED(root->FindAll(TreeScope_Descendants, condition, &found)) && found) {
            int count = 0;
            found->get_Length(&count);
            for (int i = 0; i < count; ++i) {
                IUIAutomationElement* element = nullptr;
                if (FAILED(found->GetElement(i, &element)) || !element) continue;
                BSTR label = nullptr;
                std::string text;
                if (SUCCEEDED(element->get_CurrentName(&label)) && label) {
                    text = narrow(label);
                    // Tooltips are multi-line ("OneDrive - Personal\r\nBacked
                    // up and synced"); only the first line identifies the app.
                    const auto brk = text.find_first_of("\r\n");
                    if (brk != std::string::npos) text.erase(brk);
                }
                if (label) SysFreeString(label);
                names.push_back(std::move(text));
                elements.push_back(element); // ownership moves to the caller
            }
            found->Release();
        }
        condition->Release();
    }
    VariantClear(&want);
    root->Release();
}

} // namespace

std::vector<TrayIcon> trayIcons() {
    HKEY root = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Control Panel\\NotifyIconSettings", 0, KEY_READ,
                      &root) != ERROR_SUCCESS)
        return {};

    const auto live = liveImages();

    struct Candidate {
        TrayIcon icon;
        bool fromTooltip = false;
    };
    // One registration survives per executable, then per label. NVIDIA files
    // three entries against a single executable and only one of them carries
    // the name a user recognises, so a tooltip-derived label outranks a
    // FileDescription one ("NVIDIA Settings" over "NVIDIA Container"), and a
    // promoted entry outranks a hidden one.
    const auto outranks = [](const Candidate& lhs, const Candidate& rhs) {
        if (lhs.fromTooltip != rhs.fromTooltip) return lhs.fromTooltip;
        return !lhs.icon.hidden && rhs.icon.hidden;
    };
    const auto keep = [&outranks](auto& table, auto key, Candidate&& candidate) {
        const auto existing = table.find(key);
        if (existing == table.end())
            table.emplace(std::move(key), std::move(candidate));
        else if (outranks(candidate, existing->second))
            existing->second = std::move(candidate);
    };

    std::map<std::wstring, Candidate> byExecutable;

    for (DWORD index = 0;; ++index) {
        wchar_t keyName[256];
        DWORD length = static_cast<DWORD>(std::size(keyName));
        const LSTATUS status =
            RegEnumKeyExW(root, index, keyName, &length, nullptr, nullptr, nullptr, nullptr);
        if (status == ERROR_NO_MORE_ITEMS) break;
        if (status != ERROR_SUCCESS) continue;

        HKEY entry = nullptr;
        if (RegOpenKeyExW(root, keyName, 0, KEY_READ, &entry) != ERROR_SUCCESS) continue;

        const std::wstring path = resolvePath(regString(entry, L"ExecutablePath"));
        const std::wstring leaf = lower(baseName(path));
        // Explorer's own icons cannot be told apart or named from here.
        if (path.empty() || leaf == L"explorer.exe" || !isLive(live, lower(path), leaf)) {
            RegCloseKey(entry);
            continue;
        }

        std::string label = narrow(regString(entry, L"InitialTooltip"));
        const auto brk = label.find_first_of("\r\n");
        if (brk != std::string::npos) label.erase(brk);
        while (!label.empty() && (label.back() == ' ' || label.back() == '\t')) label.pop_back();

        Candidate candidate;
        candidate.fromTooltip = !label.empty();
        if (label.empty()) label = fileDescription(path);

        // No tooltip and no FileDescription means a registration with no
        // presentable identity; the bare file stem would be noise in the list.
        if (!label.empty()) {
            candidate.icon.name = std::move(label);
            candidate.icon.hidden = !regFlag(entry, L"IsPromoted");
            candidate.icon.exePath = narrow(path);
            // The registered snapshot IS the tray icon the user recognises.
            // Where there is none, the shell icon of the owning executable is
            // the closest honest stand-in.
            candidate.icon.iconSource = cacheIconPng(regBinary(entry, L"IconSnapshot"));
            if (candidate.icon.iconSource.empty())
                candidate.icon.iconSource = "exe." + candidate.icon.exePath;
            keep(byExecutable, lower(path), std::move(candidate));
        }
        RegCloseKey(entry);
    }
    RegCloseKey(root);

    // Then collapse duplicate labels across different executables, so NVIDIA's
    // two container binaries do not both render as one indistinguishable name.
    std::map<std::string, Candidate> byLabel;
    for (auto& [path, candidate] : byExecutable) {
        std::string label = candidate.icon.name;
        std::transform(label.begin(), label.end(), label.begin(), [](unsigned char c) {
            return static_cast<char>(std::tolower(c));
        });
        keep(byLabel, std::move(label), Candidate{candidate});
    }

    std::vector<TrayIcon> icons;
    icons.reserve(byLabel.size());
    for (auto& [label, candidate] : byLabel) icons.push_back(std::move(candidate.icon));

    // Promoted first (they mirror what the taskbar itself shows), then by name.
    std::sort(icons.begin(), icons.end(), [](const TrayIcon& a, const TrayIcon& b) {
        if (a.hidden != b.hidden) return !a.hidden;
        return _stricmp(a.name.c_str(), b.name.c_str()) < 0;
    });
    return icons;
}

std::string serializeTrayIcons(const std::vector<TrayIcon>& icons) {
    nlohmann::json out = nlohmann::json::array();
    for (const auto& icon : icons)
        out.push_back({{"name", icon.name}, {"hidden", icon.hidden}, {"icon", icon.iconSource}});
    return out.dump(2);
}

std::string invokeTrayIcon(const std::string& name) {
    // 1. Real tray activation, when the element exists. Promoted icons always
    //    resolve; overflow ones only while Explorer's flyout window is alive.
    //    UIA labels carry status text the registry name lacks ("OneDrive" vs
    //    "OneDrive - Personal"), so a prefix match is what lines them up.
    {
        AutomationSession session;
        if (session.automation) {
            std::vector<std::string> names;
            std::vector<IUIAutomationElement*> elements;
            collectElements(session.automation, FindWindowW(L"Shell_TrayWnd", nullptr), names,
                            elements);
            collectElements(session.automation,
                            FindWindowW(L"TopLevelWindowForOverflowXamlIsland", nullptr), names,
                            elements);

            bool invoked = false;
            for (std::size_t i = 0; i < names.size() && !invoked; ++i) {
                if (names[i].rfind(name, 0) != 0) continue;
                IUnknown* raw = nullptr;
                if (SUCCEEDED(elements[i]->GetCurrentPattern(UIA_InvokePatternId, &raw)) && raw) {
                    invoked = SUCCEEDED(static_cast<IUIAutomationInvokePattern*>(raw)->Invoke());
                    raw->Release();
                }
            }
            for (auto* element : elements) element->Release();
            if (invoked) return {};
        }
    }

    for (const auto& icon : trayIcons()) {
        if (icon.name != name || icon.exePath.empty()) continue;
        const std::wstring path = widen(icon.exePath);

        // 2. Un-minimise the window it already has. This is the case the UIA
        //    path usually cannot reach: it only sees icons currently promoted
        //    onto the taskbar or sitting in an open overflow flyout, so for
        //    most rows the element does not exist and step 1 finds nothing.
        for (const DWORD pid : verifiedPids(lower(baseName(path)), lower(path)))
            if (restoreWindowOf(pid)) return {};

        // 3. Nothing to restore, so start it. For a single-instance app this
        //    is also what raises an existing window.
        const auto result = reinterpret_cast<INT_PTR>(
            ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
        if (result > 32) return {};
        return "[!] could not activate " + name;
    }
    return "[!] no tray icon named " + name;
}

std::string closeTrayApp(const std::string& name) {
    std::string exePath;
    for (const auto& icon : trayIcons())
        if (icon.name == name) {
            exePath = icon.exePath;
            break;
        }
    if (exePath.empty()) return "[!] no tray icon named " + name;

    const std::wstring leaf = lower(baseName(widen(exePath)));
    // trayIcons() already drops explorer.exe, so this only fires if that ever
    // changes — but killing the shell from a bar built to replace the taskbar
    // is not a mistake worth leaving reachable.
    if (leaf == L"explorer.exe") return "[!] refusing to close the Windows shell";

    // The basename only PRE-FILTERS. Every candidate is then confirmed against
    // the registration's full path, because a basename is not an identity and
    // trusting it here was a live, dangerous bug: this machine has a tray
    // registration for the packaged Claude desktop app under Program Files
    // that is NOT running, while three Claude Code CLI processes — a different
    // product, in AppData — are. Basename matching aimed the terminate at
    // those three. Liveness in trayIcons() may stay loose (a stray row costs
    // nothing, and NVIDIA's SYSTEM-owned icon needs it); a kill may not.
    const std::wstring wantedPath = lower(widen(exePath));
    const DWORD self = GetCurrentProcessId();
    std::vector<CloseTarget> targets;
    std::size_t unverifiable = 0;
    for (const DWORD pid : processesForImage(leaf)) {
        if (pid == self) continue; // never close the bar itself
        // Ask for the terminate right up front: a process the bar cannot kill
        // (anything at a higher integrity level) drops out here, which is what
        // keeps system-owned icons safe without maintaining a blocklist.
        const HANDLE process =
            OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE | SYNCHRONIZE, FALSE,
                        pid);
        if (!process) {
            ++unverifiable;
            continue;
        }
        const std::wstring actual = lower(imagePathOf(process));
        // An unreadable path is an unverifiable identity, and an unverified
        // process must never be terminated. A path that simply differs is a
        // different program that happens to share an executable name.
        if (actual.empty()) ++unverifiable;
        if (actual != wantedPath) {
            CloseHandle(process);
            continue;
        }
        targets.push_back({process, pid});
    }
    if (targets.empty()) {
        // Distinguish the two, because "not running" would be a lie about
        // Task Manager or NVIDIA's SYSTEM-owned icon: both are running, the
        // bar just has no right to inspect or end them.
        if (unverifiable > 0) return "[!] " + name + " runs above the bar's privileges";
        return "[!] " + name + " is not running";
    }

    for (const auto& target : targets)
        EnumWindows(postCloseToOwned, static_cast<LPARAM>(target.pid));

    // Escalate off the caller's thread. A tray app's usual answer to WM_CLOSE
    // is to hide, so waiting and then forcing is the only thing that removes
    // it — but a process still showing a window is mid-conversation with the
    // user (an unsaved-work prompt), and killing that would destroy exactly
    // what the polite first step exists to protect.
    std::thread([targets = std::move(targets)]() mutable {
        std::this_thread::sleep_for(std::chrono::seconds(5));
        for (auto& target : targets) {
            if (WaitForSingleObject(target.handle, 0) == WAIT_TIMEOUT &&
                !hasVisibleWindow(target.pid))
                TerminateProcess(target.handle, 0);
            CloseHandle(target.handle);
        }
    }).detach();
    return {};
}

} // namespace ybar::providers
