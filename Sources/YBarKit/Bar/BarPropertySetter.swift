import Foundation

/// `--bar <prop>=<value>` handling. Float and color leaves are animatable
/// through the same scheduler as item properties (bar height/color animations
/// are a marquee sketchybar feature).
@MainActor
public enum BarPropertySetter {
    public static func set(manager: BarManager, property: String, value: String,
                           context: PropertyContext) -> String? {
        let path = property.split(separator: ".", omittingEmptySubsequences: false)
        guard let head = path.first else { return "[!] empty property" }
        let rest = path.dropFirst()

        switch head {
        case "position":
            guard let position = BarPosition(rawValue: value) else { return "[!] invalid position: \(value)" }
            manager.settings.position = position
            return nil
        case "height":
            return setFloat(manager, \BarManager.settings.height, "height", value, context)
        case "margin":
            return setFloat(manager, \BarManager.settings.margin, "margin", value, context)
        case "y_offset":
            return setFloat(manager, \BarManager.settings.yOffset, "y_offset", value, context)
        case "padding_left":
            return setFloat(manager, \BarManager.settings.paddingLeft, "padding_left", value, context)
        case "padding_right":
            return setFloat(manager, \BarManager.settings.paddingRight, "padding_right", value, context)
        case "color":
            return setColor(manager, \BarManager.settings.backgroundColor, "color", rest, value, context)
        case "border_color":
            return setColor(manager, \BarManager.settings.borderColor, "border_color", rest, value, context)
        case "border_width":
            return setFloat(manager, \BarManager.settings.borderWidth, "border_width", value, context)
        case "corner_radius":
            return setFloat(manager, \BarManager.settings.cornerRadius, "corner_radius", value, context)
        case "gradient_color":
            guard let color = YColor.parse(value) else { return "[!] invalid color: \(value)" }
            manager.settings.gradientColor = color
            return nil
        case "gradient_angle":
            return setFloat(manager, \BarManager.settings.gradientAngle, "gradient_angle", value, context)
        case "blur_radius":
            return setFloat(manager, \BarManager.settings.blurRadius, "blur_radius", value, context)
        case "idle_inhibit":
            let flag: Bool
            if value == "toggle" { flag = !manager.settings.idleInhibit }
            else if let parsed = PropertySetter.parseBool(value) { flag = parsed }
            else { return "[!] invalid boolean: \(value)" }
            manager.setIdleInhibit(flag)
            return nil
        case "shadow":
            guard let flag = PropertySetter.parseBool(value) else { return "[!] invalid boolean: \(value)" }
            manager.settings.shadow = flag
            return nil
        case "hidden":
            if value == "toggle" {
                manager.settings.hidden.toggle()
                return nil
            }
            guard let flag = PropertySetter.parseBool(value) else { return "[!] invalid boolean: \(value)" }
            manager.settings.hidden = flag
            return nil
        case "topmost":
            guard let level = BarLevel(rawValue: value) else { return "[!] invalid topmost: \(value)" }
            manager.settings.level = level
            return nil
        case "sticky":
            guard let flag = PropertySetter.parseBool(value) else { return "[!] invalid boolean: \(value)" }
            manager.settings.sticky = flag
            return nil
        case "notch_width":
            return setFloat(manager, \BarManager.settings.notchWidth, "notch_width", value, context)
        case "notch_offset":
            return setFloat(manager, \BarManager.settings.notchOffset, "notch_offset", value, context)
        case "notch_display_height":
            return setFloat(manager, \BarManager.settings.notchDisplayHeight, "notch_display_height", value, context)
        case "display":
            switch value {
            case "all":
                manager.settings.displayPolicy = .all
            case "main":
                manager.settings.displayPolicy = .main
            default:
                var indices: [Int] = []
                for token in value.split(separator: ",") {
                    guard let index = Int(token), index >= 1 else { return "[!] invalid display list: \(value)" }
                    indices.append(index)
                }
                manager.settings.displayPolicy = .list(indices)
            }
            return nil
        case "glass":
            guard let flag = PropertySetter.parseBool(value) else { return "[!] invalid boolean: \(value)" }
            manager.settings.glass = flag
            return nil
        case "fullscreen_show", "show_in_fullscreen":
            guard let flag = PropertySetter.parseBool(value) else { return "[!] invalid boolean: \(value)" }
            manager.settings.fullscreenShow = flag
            manager.updateFullscreenElevation()
            return nil
        case "wifi_ssid_prompt":
            guard let flag = PropertySetter.parseBool(value) else { return "[!] invalid boolean: \(value)" }
            if flag { DaemonHooks.shared.requestLocation?() }
            return nil
        case "font_smoothing":
            // Accepted for config compatibility; not applicable to the public-API v1 surface.
            return nil
        default:
            return "[?] unknown bar property: \(property)"
        }
    }

    private static func setFloat(
        _ manager: BarManager,
        _ keyPath: ReferenceWritableKeyPath<BarManager, Float>,
        _ key: String,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        guard let target = Float(value), target.isFinite else { return "[!] invalid number: \(value)" }
        let animationKey = "bar.\(key)"
        if let animation = ctx.animation, animation.durationFrames > 0 {
            let invalidate = ctx.invalidate
            ctx.scheduler.animate(
                key: animationKey,
                from: .float(manager[keyPath: keyPath]),
                to: .float(target),
                durationFrames: animation.durationFrames,
                curve: animation.curve
            ) { [weak manager] animValue in
                guard case .float(let current) = animValue else { return }
                manager?[keyPath: keyPath] = current
                invalidate()
            }
        } else {
            ctx.scheduler.cancel(key: animationKey)
            manager[keyPath: keyPath] = target
            ctx.invalidate()
        }
        return nil
    }

    private static func setColor(
        _ manager: BarManager,
        _ keyPath: ReferenceWritableKeyPath<BarManager, YColor>,
        _ key: String,
        _ path: ArraySlice<Substring>,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        if let channel = path.first {
            switch channel {
            case "alpha":
                return setFloat(manager, keyPath.appending(path: \YColor.alpha), "\(key).alpha", value, ctx)
            case "red":
                return setFloat(manager, keyPath.appending(path: \YColor.red), "\(key).red", value, ctx)
            case "green":
                return setFloat(manager, keyPath.appending(path: \YColor.green), "\(key).green", value, ctx)
            case "blue":
                return setFloat(manager, keyPath.appending(path: \YColor.blue), "\(key).blue", value, ctx)
            case "hex":
                break
            default:
                return "[?] unknown color channel: \(channel)"
            }
        }
        guard let target = YColor.parse(value) else { return "[!] invalid color: \(value)" }
        let animationKey = "bar.\(key)"
        if let animation = ctx.animation, animation.durationFrames > 0 {
            let invalidate = ctx.invalidate
            ctx.scheduler.animate(
                key: animationKey,
                from: .color(manager[keyPath: keyPath]),
                to: .color(target),
                durationFrames: animation.durationFrames,
                curve: animation.curve
            ) { [weak manager] animValue in
                guard case .color(let current) = animValue else { return }
                manager?[keyPath: keyPath] = current
                invalidate()
            }
        } else {
            ctx.scheduler.cancel(key: animationKey)
            manager[keyPath: keyPath] = target
            ctx.invalidate()
        }
        return nil
    }
}
