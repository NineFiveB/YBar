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
// clang-format on

#include <cstdio>

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
                    // Tooltips are multi-line ("OneDrive - Personal\r\nBacked
                    // up and synced"); a bar row shows the first line only.
                    const auto brk = icon.name.find_first_of("\r\n");
                    if (brk != std::string::npos) icon.name.erase(brk);
                    if (icon.name.empty()) {
                        SysFreeString(name);
                        element->Release();
                        continue;
                    }
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

} // namespace

std::vector<TrayIcon> trayIcons() {
    AutomationSession session;
    return enumerate(nullptr, session);
}

std::string serializeTrayIcons(const std::vector<TrayIcon>& icons) {
    nlohmann::json out = nlohmann::json::array();
    for (const auto& icon : icons)
        out.push_back({{"name", icon.name}, {"hidden", icon.hidden}});
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
