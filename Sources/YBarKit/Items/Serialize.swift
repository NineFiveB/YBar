import AppKit
import Foundation

/// `--query` JSON output. Key names follow sketchybar's shapes where they exist —
/// scripts in the wild pipe this straight into `jq`.
@MainActor
public enum Serialize {
    public static func query(target: String, manager: BarManager, eventBus: EventBus) -> String {
        switch target {
        case "bar":
            return json(barDictionary(manager: manager))
        case "defaults":
            return json(itemDictionary(manager.store.defaults))
        case "events":
            var events: [String: Any] = [:]
            for definition in eventBus.definitions {
                events[definition.name] = [
                    "bit": definition.bit,
                    "notification": definition.notificationName ?? "(null)",
                ]
            }
            return json(events)
        case "displays":
            return json(displaysArray())
        default:
            guard let item = manager.store.item(named: target) else {
                return "[!] no item named \(target)"
            }
            return json(itemDictionary(item, boundingRects: manager.boundingRects(for: item)))
        }
    }

    static func barDictionary(manager: BarManager) -> [String: Any] {
        let settings = manager.settings
        return [
            "position": settings.position.rawValue,
            "height": settings.height,
            "margin": settings.margin,
            "y_offset": settings.yOffset,
            "padding_left": settings.paddingLeft,
            "padding_right": settings.paddingRight,
            "color": hex(settings.backgroundColor),
            "border_color": hex(settings.borderColor),
            "border_width": settings.borderWidth,
            "corner_radius": settings.cornerRadius,
            "blur_radius": settings.blurRadius,
            "hidden": settings.hidden,
            "topmost": settings.level.rawValue,
            "sticky": settings.sticky,
            "notch_width": settings.notchWidth,
            "items": manager.store.items.map(\.name),
        ]
    }

    static func itemDictionary(_ item: Item, boundingRects: [String: [String: Any]] = [:]) -> [String: Any] {
        var dictionary: [String: Any] = [
            "name": item.name,
            "type": item.kind.rawValue,
            "geometry": [
                "drawing": item.drawing ? "on" : "off",
                "position": item.position.rawValue,
                "associated_display_mask": item.associatedDisplayMask,
                "y_offset": item.yOffset,
                "padding_left": item.paddingLeft,
                "padding_right": item.paddingRight,
                "width": item.customWidth,
                "align": String(item.align),
                "background": backgroundDictionary(item.background),
            ] as [String: Any],
            "icon": textDictionary(item.icon),
            "label": textDictionary(item.label),
            "scripting": [
                "script": item.script,
                "click_script": item.clickScript,
                "update_freq": item.updateFrequency,
                "update_mask": item.updateMask,
                "updates": item.updatePolicy.rawValue,
            ] as [String: Any],
            "bounding_rects": boundingRects,
        ]

        if item.kind == .bracket {
            dictionary["bracket"] = item.members
        }
        if let graph = item.graph {
            dictionary["graph"] = [
                "width": graph.capacity,
                "color": hex(graph.lineColor),
                "fill_color": hex(graph.effectiveFillColor),
                "line_width": graph.lineWidth,
            ] as [String: Any]
        }
        if let slider = item.slider {
            dictionary["slider"] = [
                "percentage": slider.percentage,
                "width": slider.width,
                "highlight_color": hex(slider.highlightColor),
            ] as [String: Any]
        }
        if let gauge = item.gauge {
            dictionary["gauge"] = [
                "percentage": gauge.percentage,
                "size": gauge.diameter,
                "thickness": gauge.thickness,
                "color": hex(gauge.color),
                "track_color": hex(gauge.trackColor),
            ] as [String: Any]
        }
        dictionary["popup"] = [
            "drawing": item.popup.isOpen ? "on" : "off",
            "horizontal": item.popup.horizontal,
            "height": item.popup.cellHeight,
            "auto_close": item.popup.autoClose,
        ] as [String: Any]
        if item.position == .popup {
            dictionary["popup_host"] = item.popupHost ?? ""
        }
        return dictionary
    }

    static func textDictionary(_ part: TextPart) -> [String: Any] {
        [
            "value": part.string,
            "drawing": part.drawing ? "on" : "off",
            "color": hex(part.color),
            "highlight": part.highlight,
            "highlight_color": hex(part.highlightColor),
            "font": part.font.description,
            "padding_left": part.paddingLeft,
            "padding_right": part.paddingRight,
            "y_offset": part.yOffset,
            "max_chars": part.maxChars,
            "background": backgroundDictionary(part.background),
        ]
    }

    static func backgroundDictionary(_ background: BackgroundStyle) -> [String: Any] {
        [
            "drawing": background.drawing ? "on" : "off",
            "color": hex(background.color),
            "border_color": hex(background.borderColor),
            "border_width": background.borderWidth,
            "corner_radius": background.cornerRadius,
            "height": background.height,
            "padding_left": background.paddingLeft,
            "padding_right": background.paddingRight,
            "x_offset": background.xOffset,
            "y_offset": background.yOffset,
            "shadow": [
                "drawing": background.shadow.drawing ? "on" : "off",
                "color": hex(background.shadow.color),
                "distance": background.shadow.distance,
                "angle": background.shadow.angle,
            ] as [String: Any],
        ]
    }

    static func displaysArray() -> [[String: Any]] {
        DisplayManager.screens().map { index, screen in
            let frame = screen.frame
            return [
                "arrangement-id": index,
                "frame": [
                    "x": frame.origin.x, "y": frame.origin.y,
                    "w": frame.size.width, "h": frame.size.height,
                ] as [String: Any],
                "scale": screen.backingScaleFactor,
            ]
        }
    }

    static func hex(_ color: YColor) -> String {
        String(format: "0x%08x", color.argb)
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else { return "[!] serialization failed" }
        return text
    }
}
