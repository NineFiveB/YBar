// Menu-bar status item bridge for the ybar "menu bar items" widget.
// Enumerates third-party apps' NSStatusItems via the Accessibility API
// (each app exposes an AXExtrasMenuBar with pressable children) and can
// press one to open its menu — works even while the native menu bar is
// auto-hidden. Requires Accessibility permission for the calling context.
//
//   statusitems list              ->  pid \t app name \t item index \t item count
//   statusitems menu PID IDX [PATH]  ->  index \t enabled \t submenu \t title
//   statusitems item PID IDX PATH    ->  invokes that menu entry
//   statusitems press PID IDX     ->  presses the item itself (opens its menu
//                                     on screen; the fallback for items that
//                                     expose no AXMenu)
//
// Why `menu`/`item` exist. Pressing a status item is unreliable and, on a bar
// that covers the native strip, unhelpful even when it works: AXPress returns
// kAXErrorCannotComplete for a good share of apps (measured here: AeroSpace
// and Raycast fail, Creative Cloud succeeds), and a synthetic click — posted
// to the owning pid or to the HID tap — reaches nothing, because the strip is
// auto-hidden and covered.
//
// But the menu itself is readable without opening anything: a status item
// carries its AXMenu as a child, whose AXMenuItem children can be enumerated
// and AXPress'd directly. That is how a row reaches "Settings…" on an app
// whose icon lives in the bar YBar replaced. PATH is a dot-separated index
// chain so a submenu entry is addressable ("39.2").
//
// Build: swiftc -O statusitems.swift -o bin/statusitems

import AppKit
import ApplicationServices

func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value = value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

func children(of element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
          let array = value as? [AXUIElement] else { return [] }
    return array
}

func extrasBar(_ pid: pid_t) -> AXUIElement? {
    let app = AXUIElementCreateApplication(pid)
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &value) == .success else {
        return nil
    }
    return axElement(value)
}

guard AXIsProcessTrusted() else {
    print("NOAX")
    exit(1)
}

let args = CommandLine.arguments

/// The AXMenu a status item owns, if it has one. Present without the menu
/// ever being opened, which is the whole point.
func itemMenu(_ item: AXUIElement) -> AXUIElement? {
    children(of: item).first { element in
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return (role as? String) == (kAXMenuRole as String)
    }
}

func title(of element: AXUIElement) -> String {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
    return (value as? String) ?? ""
}

func isEnabled(_ element: AXUIElement) -> Bool {
    var value: CFTypeRef?
    AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value)
    return (value as? Bool) ?? false
}

/// Walk a dot-separated index chain from a menu down through submenus.
/// "13" is the 14th entry of this menu; "39.2" is the 3rd entry of the
/// submenu hanging off the 40th.
func entry(in menu: AXUIElement, path: [Int]) -> AXUIElement? {
    var current = menu
    for (depth, index) in path.enumerated() {
        let entries = children(of: current)
        guard index >= 0, index < entries.count else { return nil }
        let element = entries[index]
        if depth == path.count - 1 { return element }
        guard let submenu = itemMenu(element) else { return nil }
        current = submenu
    }
    return nil
}

func statusItem(pid: pid_t, index: Int) -> AXUIElement? {
    guard let bar = extrasBar(pid) else { return nil }
    let items = children(of: bar)
    guard index >= 0, index < items.count else { return nil }
    return items[index]
}

// menu: list an item's entries (or a submenu's) without opening anything.
if args.count >= 4, args[1] == "menu", let pid = pid_t(args[2]), let index = Int(args[3]) {
    guard let item = statusItem(pid: pid, index: index), let menu = itemMenu(item) else { exit(1) }
    let path = args.count >= 5 ? args[4].split(separator: ".").compactMap { Int($0) } : []
    let container = path.isEmpty ? menu : entry(in: menu, path: path).flatMap(itemMenu)
    guard let container else { exit(1) }
    for (i, element) in children(of: container).enumerated() {
        // A separator is a blank, disabled entry; the widget drops them.
        print("\(i)\t\(isEnabled(element) ? 1 : 0)\t\(itemMenu(element) != nil ? 1 : 0)\t\(title(of: element))")
    }
    exit(0)
}

// item: invoke one entry. AXPress on a menu item works even though AXPress on
// the status item that owns it may not — the failure is in opening the menu,
// not in the menu.
if args.count >= 5, args[1] == "item", let pid = pid_t(args[2]), let index = Int(args[3]) {
    let path = args[4].split(separator: ".").compactMap { Int($0) }
    guard !path.isEmpty, let item = statusItem(pid: pid, index: index),
          let menu = itemMenu(item), let target = entry(in: menu, path: path)
    else { exit(1) }
    exit(AXUIElementPerformAction(target, kAXPressAction as CFString) == .success ? 0 : 1)
}

if args.count >= 4, args[1] == "press", let pid = pid_t(args[2]), let index = Int(args[3]) {
    guard let bar = extrasBar(pid) else { exit(1) }
    let items = children(of: bar)
    guard index >= 0, index < items.count else { exit(1) }
    exit(AXUIElementPerformAction(items[index], kAXPressAction as CFString) == .success ? 0 : 1)
}

// list: third-party apps only — Apple's own extras (Control Center hosts
// the system icons) are already covered by ybar's widgets.
for app in NSWorkspace.shared.runningApplications {
    let pid = app.processIdentifier
    guard pid > 0 else { continue }
    if let bundle = app.bundleIdentifier, bundle.hasPrefix("com.apple.") { continue }
    guard let bar = extrasBar(pid) else { continue }
    let count = children(of: bar).count
    guard count > 0 else { continue }
    let name = app.localizedName ?? "App \(pid)"
    for index in 0..<count {
        print("\(pid)\t\(name)\t\(index)\t\(count)")
    }
}
