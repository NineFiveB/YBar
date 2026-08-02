// Menu-bar status item bridge for the ybar "menu bar items" widget.
// Enumerates third-party apps' NSStatusItems via the Accessibility API
// (each app exposes an AXExtrasMenuBar with pressable children) and can
// press one to open its menu — works even while the native menu bar is
// auto-hidden. Requires Accessibility permission for the calling context.
//
//   statusitems list           ->  pid \t app name \t item index \t item count
//   statusitems press PID IDX  ->  opens that status item's menu
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
