// Notification-area (system tray) icons — Windows extension, supersedes the
// "impossible" note in spec 10.6.
//
// Source of record is HKCU\Control Panel\NotifyIconSettings — the registration
// list Explorer keeps for every Shell_NotifyIcon owner — filtered to the
// entries whose executable is currently running. That combination is silent,
// needs no cooperation from Explorer, and reports promoted and overflow icons
// alike.
//
// It replaced a UI Automation walk, which had two disqualifying faults:
//
//   1. Overflow icons live in TopLevelWindowForOverflowXamlIsland, a window
//      Explorer only creates while the "Show Hidden Icons" flyout is open. With
//      the taskbar hidden it does not exist, so UIA saw ONLY promoted icons —
//      measured 1 of 11 here. Forcing it open means invoking the chevron and
//      flashing Explorer's flyout on screen for every refresh.
//   2. Even with the flyout open, UIA reports an EMPTY Name for a good share of
//      icons — measured 3 of 10, and they were AMD Software, CurseForge and
//      iCloud, i.e. exactly the ones a user notices missing. The registry names
//      all three.
//
// The registry trades a little precision for that: liveness is inferred from
// "the owning executable is running", so an app that is running with its tray
// icon switched off still lists. That is the better failure — a stray row beats
// a missing one, and the alternative under-reported by an order of magnitude.
//
// Liveness matches on executable BASENAME, not full path: NVIDIA's icon is
// owned by NVDisplay.Container.exe running as SYSTEM, whose full path a normal
// process cannot read, and path matching silently dropped it.
//
// Explorer's own icons (Safely Remove Hardware, Bluetooth Devices) are omitted.
// They all report ExecutablePath=explorer.exe with FileDescription "Windows
// Explorer", so they can only be rendered as duplicate meaningless rows; the
// bar already carries Bluetooth and network as first-class pills.
//
// UIA is still used for activation, where it is the correct mechanism: Explorer
// forwards an Invoke to the owning app as the real tray callback. It only
// reaches icons whose element currently exists, so activation falls back to
// launching the owning executable.

#pragma once

#include <string>
#include <vector>

namespace ybar::providers {

struct TrayIcon {
    std::string name;    // tooltip, else the executable's FileDescription
    bool hidden = false; // not promoted onto the taskbar (behind the chevron)
    std::string exePath; // owning executable, for activation fallback
    std::string iconSource; // cached PNG path, else "exe.<path>" for the atlas
};

// One enumeration pass. Empty when the registration list is unreadable.
std::vector<TrayIcon> trayIcons();

// JSON for `--query tray`: name, hidden and icon.
std::string serializeTrayIcons(const std::vector<TrayIcon>& icons);

// `--tray "<name>" invoke` — UI Automation when the element is reachable,
// otherwise launches the owning executable. "" on success, else a message.
std::string invokeTrayIcon(const std::string& name);

// `--tray "<name>" close` — quits the app behind a tray icon, which is the
// only way to reach a background app once the shell taskbar is hidden.
//
// Task Manager's "End task" semantics, deliberately: WM_CLOSE to every window
// the owning processes have, then a terminate five seconds later for whatever
// is still alive AND no longer showing a window. WM_CLOSE alone does not work
// here — a tray app's usual response is to HIDE to the tray, precisely the
// state being escaped — and terminating outright would rob apps that quit
// cleanly of the chance to save. A process still showing a window after being
// asked to close is mid-prompt with the user, so it is spared.
//
// Targets are confirmed by FULL IMAGE PATH, never by executable basename. The
// list in trayIcons() may match loosely (a stray row is harmless, and NVIDIA's
// SYSTEM-owned icon depends on it) but a kill may not: a basename matched the
// packaged Claude desktop app's registration onto three unrelated Claude Code
// CLI processes on the author's machine. A process whose path cannot be read
// is unverifiable and is never terminated.
//
// The wait runs on a detached thread, but the call itself is NOT free: it
// re-enumerates via trayIcons() to resolve the name, which reads the registry
// and takes a process snapshot.
//
// Returns "" once the request is issued (not once the app is gone).
std::string closeTrayApp(const std::string& name);

} // namespace ybar::providers
