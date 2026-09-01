// Notification-area (system tray) icons — Windows extension, supersedes the
// "impossible" note in spec 10.6.
//
// The classic technique (Shell_TrayWnd > TrayNotifyWnd > SysPager >
// ToolbarWindow32 + cross-process TB_GETBUTTON/TRAYDATA) is DEAD on Windows 11
// 22H2 Moment 2 and later: TrayNotifyWnd is an empty leaf and there is no
// ToolbarWindow32 anywhere in the session (verified on 26200.9168). The XAML
// tray instead publishes every icon through UI Automation.
//
// The catch that makes this look impossible: ElementFromHandle(Shell_TrayWnd)
// returns a Pane with ZERO children while the taskbar is hidden — which is
// exactly this bar's configuration. The elements hang off the tray's
// Windows.UI.Composition.DesktopWindowContentBridge CHILD window instead.
//
// What UIA gives: the tooltip label, an InvokePattern (click activation, which
// Explorer forwards to the owning app as the real tray callback), and a clean
// visible/hidden split. What it does NOT give: the owning process (every
// element reports Explorer) or the icon bitmap — those pixels come from
// HKCU\Control Panel\NotifyIconSettings, whose IconSnapshot values are literal
// PNG files, matched back to labels by string.

#pragma once

#include <string>
#include <vector>

namespace ybar::providers {

struct TrayIcon {
    std::string name;      // UIA Name = the tooltip the user sees
    std::string iconPath;  // extracted PNG, "" when no confident match
    bool hidden = false;   // behind the overflow chevron
};

// One enumeration pass (~15-20 ms warm). Empty when the tray is unreadable.
std::vector<TrayIcon> trayIcons();

// JSON for `--query tray`.
std::string serializeTrayIcons(const std::vector<TrayIcon>& icons);

// `--tray "<name>" invoke` — re-enumerates and invokes the matching element.
// Returns "" on success, an error message otherwise.
std::string invokeTrayIcon(const std::string& name);

} // namespace ybar::providers
