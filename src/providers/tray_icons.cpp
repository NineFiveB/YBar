#include "providers/tray_icons.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <uiautomation.h>
#include <shlobj.h>
// clang-format on

#include <algorithm>
#include <cctype>
#include <cstdio>
#include <fstream>
#include <unordered_map>

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

std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

// Only [a-z0-9] kept: "NVIDIA Settings" and "nvidia-settings.exe" must collide.
std::string squash(const std::string& value) {
    std::string out;
    for (unsigned char c : value)
        if (std::isalnum(c)) out.push_back(static_cast<char>(std::tolower(c)));
    return out;
}

// ── Registry side: the icon pixels ────────────────────────────────────────
// HKCU\Control Panel\NotifyIconSettings\<id>\IconSnapshot is a literal PNG.
// Note it is a FIRST-REGISTRATION snapshot, not a live mirror, so an icon
// that changes with state (battery, sync progress) can render stale — and the
// key also retains long-dead apps, which is why UIA owns the live list and
// this is consulted only for pixels.
struct RegistryIcon {
    std::string tooltip;    // InitialTooltip
    std::string exeStem;    // ExecutablePath basename without extension
    std::vector<BYTE> png;
};

std::wstring regString(HKEY key, const wchar_t* name) {
    wchar_t buffer[1024];
    DWORD size = sizeof(buffer);
    if (RegGetValueW(key, nullptr, name, RRF_RT_REG_SZ, nullptr, buffer, &size) != ERROR_SUCCESS)
        return {};
    return buffer;
}

std::vector<RegistryIcon> registryIcons() {
    std::vector<RegistryIcon> icons;
    HKEY root = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Control Panel\\NotifyIconSettings", 0, KEY_READ,
                      &root) != ERROR_SUCCESS)
        return icons;
    for (DWORD index = 0;; ++index) {
        wchar_t subName[256];
        DWORD subLen = 256;
        if (RegEnumKeyExW(root, index, subName, &subLen, nullptr, nullptr, nullptr, nullptr) !=
            ERROR_SUCCESS)
            break;
        HKEY sub = nullptr;
        if (RegOpenKeyExW(root, subName, 0, KEY_READ, &sub) != ERROR_SUCCESS) continue;

        RegistryIcon icon;
        icon.tooltip = narrow(regString(sub, L"InitialTooltip"));
        const std::wstring exe = regString(sub, L"ExecutablePath");
        if (!exe.empty()) {
            const auto slash = exe.find_last_of(L"\\/");
            std::wstring stem = slash == std::wstring::npos ? exe : exe.substr(slash + 1);
            const auto dot = stem.find_last_of(L'.');
            if (dot != std::wstring::npos) stem = stem.substr(0, dot);
            icon.exeStem = narrow(stem);
        }
        DWORD size = 0;
        if (RegGetValueW(sub, nullptr, L"IconSnapshot", RRF_RT_REG_BINARY, nullptr, nullptr,
                         &size) == ERROR_SUCCESS &&
            size > 8) {
            icon.png.resize(size);
            if (RegGetValueW(sub, nullptr, L"IconSnapshot", RRF_RT_REG_BINARY, nullptr,
                             icon.png.data(), &size) != ERROR_SUCCESS)
                icon.png.clear();
            else
                icon.png.resize(size);
        }
        RegCloseKey(sub);
        // PNG magic — the value is a whole file, not a raw bitmap.
        const bool isPng = icon.png.size() > 8 && icon.png[0] == 0x89 && icon.png[1] == 'P' &&
                           icon.png[2] == 'N' && icon.png[3] == 'G';
        if (isPng && (!icon.tooltip.empty() || !icon.exeStem.empty()))
            icons.push_back(std::move(icon));
    }
    RegCloseKey(root);
    return icons;
}

std::wstring iconCacheDirectory() {
    PWSTR local = nullptr;
    std::wstring dir;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local)) && local) {
        dir = std::wstring(local) + L"\\ybar\\trayicons";
        CoTaskMemFree(local);
        CreateDirectoryW((std::wstring(dir).substr(0, dir.find_last_of(L'\\'))).c_str(), nullptr);
        CreateDirectoryW(dir.c_str(), nullptr);
    }
    return dir;
}

// The engine renders an image from a plain file path, so the PNG is written
// once per label and referenced by path — no new atlas source type needed.
std::string writeIconFile(const std::wstring& dir, const std::string& key,
                          const std::vector<BYTE>& png) {
    if (dir.empty() || png.empty()) return {};
    const std::wstring path = dir + L"\\" + std::wstring(key.begin(), key.end()) + L".png";
    const std::string narrowPath = narrow(path);
    std::ofstream out(narrowPath, std::ios::binary | std::ios::trunc);
    if (!out) return {};
    out.write(reinterpret_cast<const char*>(png.data()), static_cast<std::streamsize>(png.size()));
    if (!out) return {};
    return narrowPath;
}

// ── UIA side: the live list ───────────────────────────────────────────────
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

// Every tray icon element hangs off this bridge child, NOT off Shell_TrayWnd
// itself: with the taskbar hidden, ElementFromHandle(Shell_TrayWnd) yields a
// Pane with no children at all.
HWND bridgeChild(HWND host) {
    if (!host) return nullptr;
    return FindWindowExW(host, nullptr, L"Windows.UI.Composition.DesktopWindowContentBridge",
                         nullptr);
}

void collectFrom(IUIAutomation* automation, HWND host, bool hidden,
                 std::vector<TrayIcon>& out,
                 std::vector<IUIAutomationElement*>* elements) {
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
                BSTR name = nullptr;
                if (SUCCEEDED(element->get_CurrentName(&name)) && name && *name) {
                    TrayIcon icon;
                    icon.name = narrow(name);
                    icon.hidden = hidden;
                    out.push_back(std::move(icon));
                    if (elements) {
                        element->AddRef();
                        elements->push_back(element);
                    }
                }
                if (name) SysFreeString(name);
                element->Release();
            }
            found->Release();
        }
        condition->Release();
    }
    VariantClear(&want);
    root->Release();
}

std::vector<TrayIcon> enumerate(std::vector<IUIAutomationElement*>* elements,
                                AutomationSession& session) {
    std::vector<TrayIcon> icons;
    if (!session.automation) return icons;
    // Promoted (on the bar) first, then the overflow flyout's host. The
    // overflow window may only exist once the chevron has been opened at
    // least once this session — absence degrades to "promoted icons only".
    collectFrom(session.automation, FindWindowW(L"Shell_TrayWnd", nullptr), false, icons,
                elements);
    collectFrom(session.automation, FindWindowW(L"TopLevelWindowForOverflowXamlIsland", nullptr),
                true, icons, elements);
    return icons;
}

// Label -> PNG. Nothing links the two sides by id, so match on strings:
// exact/prefix on the registry tooltip first, then the executable stem.
// Deliberately conservative — a wrong icon is worse than none.
void attachIcons(std::vector<TrayIcon>& icons) {
    const auto registry = registryIcons();
    if (registry.empty()) return;
    const std::wstring dir = iconCacheDirectory();
    if (dir.empty()) return;

    for (auto& icon : icons) {
        const std::string key = squash(icon.name);
        if (key.empty()) continue;
        const RegistryIcon* best = nullptr;
        for (const auto& candidate : registry) {
            const std::string tip = squash(candidate.tooltip);
            if (!tip.empty() && (tip == key || key.rfind(tip, 0) == 0 || tip.rfind(key, 0) == 0)) {
                best = &candidate;
                break;
            }
        }
        if (!best) {
            for (const auto& candidate : registry) {
                const std::string stem = squash(candidate.exeStem);
                if (!stem.empty() && stem.size() >= 4 &&
                    (key.find(stem) != std::string::npos || stem.find(key) != std::string::npos)) {
                    best = &candidate;
                    break;
                }
            }
        }
        if (best) icon.iconPath = writeIconFile(dir, key, best->png);
    }
}

} // namespace

std::vector<TrayIcon> trayIcons() {
    AutomationSession session;
    auto icons = enumerate(nullptr, session);
    attachIcons(icons);
    return icons;
}

std::string serializeTrayIcons(const std::vector<TrayIcon>& icons) {
    nlohmann::json out = nlohmann::json::array();
    for (const auto& icon : icons)
        out.push_back({{"name", icon.name}, {"icon", icon.iconPath}, {"hidden", icon.hidden}});
    return out.dump(2);
}

std::string invokeTrayIcon(const std::string& name) {
    AutomationSession session;
    if (!session.automation) return "[!] UI Automation is unavailable";
    std::vector<IUIAutomationElement*> elements;
    const auto icons = enumerate(&elements, session);
    std::string error = "[!] no tray icon named " + name;
    for (std::size_t i = 0; i < icons.size() && i < elements.size(); ++i) {
        if (icons[i].name != name) continue;
        IUnknown* raw = nullptr;
        // Invoke is the documented activation path: Explorer forwards it to
        // the owning app as the real Shell_NotifyIcon callback, so we never
        // have to reconstruct uCallbackMessage or guess the
        // NOTIFYICON_VERSION_4 packing.
        if (SUCCEEDED(elements[i]->GetCurrentPattern(UIA_InvokePatternId, &raw)) && raw) {
            auto* invoke = static_cast<IUIAutomationInvokePattern*>(raw);
            error = SUCCEEDED(invoke->Invoke()) ? std::string{} : "[!] invoke was refused";
            raw->Release();
        } else {
            error = "[!] that tray icon cannot be invoked";
        }
        break;
    }
    for (auto* element : elements) element->Release();
    return error;
}

} // namespace ybar::providers
