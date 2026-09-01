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
#include <cstddef>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <iterator>
#include <map>
#include <set>
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

std::set<std::wstring> runningExecutables() {
    std::set<std::wstring> names;
    const HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return names;
    PROCESSENTRY32W entry{};
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            names.insert(lower(entry.szExeFile));
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return names;
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

    const auto running = runningExecutables();

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
        if (path.empty() || leaf == L"explorer.exe" || running.count(leaf) == 0) {
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
        out.push_back({{"name", icon.name}, {"hidden", icon.hidden}});
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

    // 2. Otherwise launch the owner, which is what raises the window a tray
    //    click would have raised for every app that keeps a single instance.
    for (const auto& icon : trayIcons()) {
        if (icon.name != name || icon.exePath.empty()) continue;
        const std::wstring path = widen(icon.exePath);
        const auto result = reinterpret_cast<INT_PTR>(
            ShellExecuteW(nullptr, L"open", path.c_str(), nullptr, nullptr, SW_SHOWNORMAL));
        if (result > 32) return {};
        return "[!] could not activate " + name;
    }
    return "[!] no tray icon named " + name;
}

} // namespace ybar::providers
