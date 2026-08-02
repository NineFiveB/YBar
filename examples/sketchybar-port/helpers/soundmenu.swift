// Opens the stock macOS Sound menu: finds Control Center's "Sound" menu bar
// status item window (it exists only while the module is active, e.g. AirPods
// connected) and synthesizes a click on it. With the menu bar auto-hidden the
// item may be unrealized; a burst of real mouse-move events to the top edge
// reveals the bar first (warping alone does not trigger the reveal).
// Requires Screen Recording (window names) — inherited from the YBar daemon.
// Exit 0 after clicking, 2 when the item never materialized (caller falls back).
//
// Build: swiftc -O soundmenu.swift -o bin/soundmenu

import CoreGraphics
import Foundation

func soundItemFrame() -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for entry in list {
        let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
        guard owner == "Control Center" || owner == "ControlCenter" else { continue }
        let name = (entry[kCGWindowName as String] as? String ?? "").lowercased()
        guard name.contains("sound") || name.contains("airpods") else { continue }
        guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                           width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        // Menu bar strip only — not the Control Center panel.
        guard frame.minY < 60, frame.width < 300 else { continue }
        return frame
    }
    return nil
}

func post(_ type: CGEventType, _ point: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func reveal(at x: CGFloat) {
    for y in stride(from: 240.0, through: 0.0, by: -24.0) {
        post(.mouseMoved, CGPoint(x: x, y: y))
        usleep(16000)
    }
}

func click(_ frame: CGRect) {
    // A hidden bar reports sliver-height item windows; aim at the strip center.
    let point = CGPoint(x: frame.midX, y: max(frame.midY, 12))
    post(.mouseMoved, point)
    usleep(60000)
    post(.leftMouseDown, point)
    usleep(40000)
    post(.leftMouseUp, point)
}

if let frame = soundItemFrame(), frame.height > 5 {
    click(frame)
    exit(0)
}
// Unrealized (auto-hidden menu bar): reveal near the found sliver — or the
// right end of the strip — then rescan while the bar slides in.
reveal(at: soundItemFrame()?.midX ?? 1350)
for _ in 0..<10 {
    usleep(100_000)
    if let frame = soundItemFrame(), frame.height > 5 {
        click(frame)
        exit(0)
    }
}
exit(2)
