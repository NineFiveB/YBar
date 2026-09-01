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
// element reports Explorer) or the icon bitmap.
//
// Icon pixels are deliberately NOT sourced. They exist only in
// HKCU\Control Panel\NotifyIconSettings as first-registration snapshots with
// no id linking them to a UIA element, so they have to be matched by string —
// which measured 6 of 14 labels matched, left the rest bare, and risks
// pairing a label with the WRONG app's icon. The rows are text.

#pragma once

#include <string>
#include <vector>

namespace ybar::providers {

struct TrayIcon {
    std::string name;    // UIA Name = the tooltip the user sees
    bool hidden = false; // behind the overflow chevron
};

// One enumeration pass (~15-20 ms warm). Empty when the tray is unreadable.
std::vector<TrayIcon> trayIcons();

// JSON for `--query tray`.
std::string serializeTrayIcons(const std::vector<TrayIcon>& icons);

// `--tray "<name>" invoke` — re-enumerates and invokes the matching element.
// Returns "" on success, an error message otherwise.
std::string invokeTrayIcon(const std::string& name);

} // namespace ybar::providers
