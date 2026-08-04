import Foundation

/// The dotted-path property namespace — YBar's primary compatibility surface
/// with sketchybar configs (`icon.background.shadow.color.alpha`,
/// `label.font.size`, every color addressable per channel).
///
/// Implemented as recursive descent over typed sub-parsers using key paths,
/// mirroring sketchybar's `bar_item_parse_set_message` structure. Any float or
/// color leaf is animatable: when the context carries an `--animate` modifier,
/// the set becomes a scheduled animation instead of a direct assignment.
@MainActor
public struct PropertyContext {
    public let scheduler: AnimationScheduler
    /// Active `--animate <curve> <frames>` modifier for the rest of the message.
    public var animation: (curve: AnimationCurve, durationFrames: Int)?
    public let invalidate: () -> Void
    /// Measured natural content width of an item — resolves the `width=dynamic`
    /// -1 sentinel to a real value at animation endpoints.
    public var measureNaturalWidth: ((Item) -> Float)?
    /// Same for one text part (`icon.width` / `label.width`); second arg = isIcon.
    public var measureTextNaturalWidth: ((Item, Bool) -> Float)?

    public init(scheduler: AnimationScheduler,
                animation: (curve: AnimationCurve, durationFrames: Int)? = nil,
                invalidate: @escaping () -> Void,
                measureNaturalWidth: ((Item) -> Float)? = nil,
                measureTextNaturalWidth: ((Item, Bool) -> Float)? = nil) {
        self.scheduler = scheduler
        self.animation = animation
        self.invalidate = invalidate
        self.measureNaturalWidth = measureNaturalWidth
        self.measureTextNaturalWidth = measureTextNaturalWidth
    }
}

@MainActor
public enum PropertySetter {
    /// Set one `property=value` on an item. Returns an error string or nil on success.
    public static func set(item: Item, property: String, value: String, context: PropertyContext) -> String? {
        let path = property.split(separator: ".", omittingEmptySubsequences: false)
        return setItem(item, path[...], value, context)
    }

    // MARK: - Item root

    private static func setItem(_ item: Item, _ path: ArraySlice<Substring>,
                                _ value: String, _ ctx: PropertyContext) -> String? {
        guard let head = path.first else { return "[!] empty property" }
        let rest = path.dropFirst()
        switch head {
        case "icon":
            return setText(item, \Item.icon, "icon", rest, value, ctx, isIcon: true)
        case "label":
            return setText(item, \Item.label, "label", rest, value, ctx, isIcon: false)
        case "background":
            return setBackground(item, \Item.background, "background", rest, value, ctx)
        case "position":
            guard let position = ItemPosition.parse(value) else { return "[!] invalid position: \(value)" }
            item.position = position
            ctx.invalidate()
            return nil
        case "drawing":
            return setBool(item, \Item.drawing, value, ctx)
        case "script":
            item.script = value
            return nil
        case "click_script":
            item.clickScript = value
            return nil
        case "update_freq":
            guard let frequency = Int(value), frequency >= 0 else { return "[!] invalid update_freq: \(value)" }
            item.updateFrequency = frequency
            item.routineCounter = 0
            return nil
        case "updates":
            guard let policy = UpdatePolicy(rawValue: value) ?? parseBool(value).map({ $0 ? .on : .off })
            else { return "[!] invalid updates: \(value)" }
            item.updatePolicy = policy
            return nil
        case "width":
            return setWidth(item, value, ctx)
        case "align":
            guard let first = value.first, "lcr".contains(first) else { return "[!] invalid align: \(value)" }
            item.align = first
            ctx.invalidate()
            return nil
        case "y_offset":
            return setFloat(item, \Item.yOffset, "y_offset", value, ctx)
        case "padding_left":
            return setFloat(item, \Item.paddingLeft, "padding_left", value, ctx)
        case "padding_right":
            return setFloat(item, \Item.paddingRight, "padding_right", value, ctx)
        case "display", "associated_display":
            return setDisplayAssociation(item, value, ctx)
        case "blur_radius":
            return setFloat(item, \Item.blurRadius, "blur_radius", value, ctx)
        case "scroll_texts":
            guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
            item.scrollTexts = flag
            ctx.invalidate()
            return nil
        case "tooltip":
            item.tooltip = value
            return nil
        case "padding_top", "padding_bottom",
             "space", "associated_space", "ignore_association", "mach_helper", "shadow":
            // Accepted-and-ignored for sketchybar config compatibility.
            return nil
        case "graph":
            return setGraph(item, rest, value, ctx)
        case "slider":
            return setSlider(item, rest, value, ctx)
        case "gauge":
            return setGauge(item, rest, value, ctx)
        case "image":
            return setImage(item, rest, value, ctx)
        case "alias":
            guard let alias = item.alias else { return "[!] \(item.name) is not an alias" }
            switch rest.first {
            case "scale":
                guard let scale = Float(value), scale.isFinite, scale > 0 else { return "[!] invalid alias.scale: \(value)" }
                alias.scale = scale
                ctx.invalidate()
                return nil
            case "color", "update_freq":
                return nil  // accepted (tinting not implemented; update_freq is item-level)
            default:
                return "[?] unknown property: alias.\(rest.joined(separator: "."))"
            }
        case "popup":
            return setPopup(item, rest, value, ctx)
        default:
            return "[?] unknown property: \(path.joined(separator: "."))"
        }
    }

    // MARK: - Component sub-domains

    private static func setGraph(_ item: Item, _ path: ArraySlice<Substring>,
                                 _ value: String, _ ctx: PropertyContext) -> String? {
        guard let graph = item.graph else { return "[!] \(item.name) is not a graph" }
        switch path.first {
        case "color":
            return setColorValue(key: "item.\(item.id).graph.color", current: graph.lineColor,
                                 value: value, ctx: ctx) { graph.lineColor = $0 }
        case "fill_color":
            return setColorValue(key: "item.\(item.id).graph.fill_color",
                                 current: graph.fillColor ?? graph.effectiveFillColor,
                                 value: value, ctx: ctx) { graph.fillColor = $0 }
        case "line_width":
            return setFloatValue(key: "item.\(item.id).graph.line_width", current: graph.lineWidth,
                                 value: value, ctx: ctx) { graph.lineWidth = $0 }
        default:
            return "[?] unknown property: graph.\(path.joined(separator: "."))"
        }
    }

    private static func setImage(_ item: Item, _ path: ArraySlice<Substring>,
                                 _ value: String, _ ctx: PropertyContext) -> String? {
        // Lazily attach: any image.* set (or bare image=<source>) enables it.
        if item.image == nil { item.image = ImageState() }
        guard let image = item.image else { return nil }
        switch path.first {
        case nil, "string":
            image.source = value
            return nil
        case "drawing":
            guard let flag = parseBool(value) else { return "[!] invalid image.drawing: \(value)" }
            image.drawing = flag
            return nil
        case "size":
            return setFloatValue(key: "item.\(item.id).image.size", current: image.size,
                                 value: value, ctx: ctx) { image.size = max(1, $0) }
        case "padding_left":
            return setFloatValue(key: "item.\(item.id).image.padding_left", current: image.paddingLeft,
                                 value: value, ctx: ctx) { image.paddingLeft = $0 }
        case "padding_right":
            return setFloatValue(key: "item.\(item.id).image.padding_right", current: image.paddingRight,
                                 value: value, ctx: ctx) { image.paddingRight = $0 }
        case "rotation":
            return setFloatValue(key: "item.\(item.id).image.rotation", current: image.rotation,
                                 value: value, ctx: ctx) { image.rotation = $0 }
        case "align":
            image.align = value.hasPrefix("r") ? "r" : "l"
            ctx.invalidate()
            return nil
        default:
            return "[?] unknown property: image.\(path.joined(separator: "."))"
        }
    }

    private static func setGauge(_ item: Item, _ path: ArraySlice<Substring>,
                                 _ value: String, _ ctx: PropertyContext) -> String? {
        // Lazily attach: any gauge.* set turns the item into a gauge.
        if item.gauge == nil { item.gauge = GaugeState() }
        guard let gauge = item.gauge else { return nil }
        switch path.first {
        case "percentage":
            return setFloatValue(key: "item.\(item.id).gauge.percentage", current: gauge.percentage,
                                 value: value, ctx: ctx) { gauge.percentage = min(100, max(0, $0)) }
        case "size":
            return setFloatValue(key: "item.\(item.id).gauge.size", current: gauge.diameter,
                                 value: value, ctx: ctx) { gauge.diameter = max(8, $0) }
        case "thickness":
            return setFloatValue(key: "item.\(item.id).gauge.thickness", current: gauge.thickness,
                                 value: value, ctx: ctx) { gauge.thickness = max(1, $0) }
        case "color":
            return setColorValue(key: "item.\(item.id).gauge.color", current: gauge.color,
                                 value: value, ctx: ctx) { gauge.color = $0 }
        case "track_color":
            return setColorValue(key: "item.\(item.id).gauge.track_color", current: gauge.trackColor,
                                 value: value, ctx: ctx) { gauge.trackColor = $0 }
        default:
            return "[?] unknown property: gauge.\(path.joined(separator: "."))"
        }
    }

    private static func setSlider(_ item: Item, _ path: ArraySlice<Substring>,
                                  _ value: String, _ ctx: PropertyContext) -> String? {
        guard let slider = item.slider else { return "[!] \(item.name) is not a slider" }
        let rest = path.dropFirst()
        switch path.first {
        case "percentage":
            // Live drags own the visual position; a concurrent --set must not fight them.
            guard !slider.isDragged else { return nil }
            return setFloatValue(key: "item.\(item.id).slider.percentage", current: slider.percentage,
                                 value: value, ctx: ctx) { slider.percentage = min(100, max(0, $0)) }
        case "width":
            return setFloatValue(key: "item.\(item.id).slider.width", current: slider.width,
                                 value: value, ctx: ctx) { slider.width = max(1, $0) }
        case "highlight_color":
            return setColorValue(key: "item.\(item.id).slider.highlight_color",
                                 current: slider.highlightColor,
                                 value: value, ctx: ctx) { slider.highlightColor = $0 }
        case "knob":
            if rest.isEmpty {
                slider.knob.string = value
                ctx.invalidate()
                return nil
            }
            switch rest.first {
            case "string":
                slider.knob.string = value
                ctx.invalidate()
                return nil
            case "drawing":
                guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
                slider.knob.drawing = flag
                ctx.invalidate()
                return nil
            case "color":
                return setColorValue(key: "item.\(item.id).slider.knob.color",
                                     current: slider.knob.color,
                                     value: value, ctx: ctx) { slider.knob.color = $0 }
            case "font":
                slider.knob.font.apply(value)
                ctx.invalidate()
                return nil
            case "y_offset":
                return setFloatValue(key: "item.\(item.id).slider.knob.y_offset",
                                     current: slider.knob.yOffset,
                                     value: value, ctx: ctx) { slider.knob.yOffset = $0 }
            default:
                return "[?] unknown property: slider.knob.\(rest.joined(separator: "."))"
            }
        case "background":
            switch rest.first {
            case "color":
                return setColorValue(key: "item.\(item.id).slider.background.color",
                                     current: slider.background.color,
                                     value: value, ctx: ctx) { slider.background.color = $0 }
            case "height":
                return setFloatValue(key: "item.\(item.id).slider.background.height",
                                     current: slider.background.height,
                                     value: value, ctx: ctx) { slider.background.height = $0 }
            case "corner_radius":
                return setFloatValue(key: "item.\(item.id).slider.background.corner_radius",
                                     current: slider.background.cornerRadius,
                                     value: value, ctx: ctx) { slider.background.cornerRadius = $0 }
            default:
                return "[?] unknown property: slider.background.\(rest.joined(separator: "."))"
            }
        default:
            return "[?] unknown property: slider.\(path.joined(separator: "."))"
        }
    }

    private static func setPopup(_ item: Item, _ path: ArraySlice<Substring>,
                                 _ value: String, _ ctx: PropertyContext) -> String? {
        let rest = path.dropFirst()
        switch path.first {
        case "drawing":
            if value == "toggle" {
                item.popup.isOpen.toggle()
            } else if let flag = parseBool(value) {
                item.popup.isOpen = flag
            } else {
                return "[!] invalid boolean: \(value)"
            }
            ctx.invalidate()
            return nil
        case "horizontal":
            guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
            item.popup.horizontal = flag
            ctx.invalidate()
            return nil
        case "wrap_width":
            guard let width = Float(value), width.isFinite else { return "[!] invalid wrap_width: \(value)" }
            item.popup.wrapWidth = max(0, width)
            ctx.invalidate()
            return nil
        case "auto_close":
            guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
            item.popup.autoClose = flag
            ctx.invalidate()
            return nil
        case "align":
            guard let first = value.first, "lcr".contains(first) else { return "[!] invalid align: \(value)" }
            item.popup.align = first
            ctx.invalidate()
            return nil
        case "blur_radius":
            return setFloatValue(key: "item.\(item.id).popup.blur_radius",
                                 current: item.popup.blurRadius,
                                 value: value, ctx: ctx) { [weak item] in item?.popup.blurRadius = $0 }
        case "topmost":
            return nil
        case "height":
            return setFloatValue(key: "item.\(item.id).popup.height", current: item.popup.cellHeight,
                                 value: value, ctx: ctx) { [weak item] in item?.popup.cellHeight = $0 }
        case "y_offset":
            return setFloatValue(key: "item.\(item.id).popup.y_offset", current: item.popup.yOffset,
                                 value: value, ctx: ctx) { [weak item] in item?.popup.yOffset = $0 }
        case "background":
            switch rest.first {
            case "color":
                return setColorValue(key: "item.\(item.id).popup.background.color",
                                     current: item.popup.background.color,
                                     value: value, ctx: ctx) { [weak item] in item?.popup.background.color = $0 }
            case "corner_radius":
                return setFloatValue(key: "item.\(item.id).popup.background.corner_radius",
                                     current: item.popup.background.cornerRadius,
                                     value: value, ctx: ctx) { [weak item] in item?.popup.background.cornerRadius = $0 }
            case "border_color":
                return setColorValue(key: "item.\(item.id).popup.background.border_color",
                                     current: item.popup.background.borderColor,
                                     value: value, ctx: ctx) { [weak item] in item?.popup.background.borderColor = $0 }
            case "border_width":
                return setFloatValue(key: "item.\(item.id).popup.background.border_width",
                                     current: item.popup.background.borderWidth,
                                     value: value, ctx: ctx) { [weak item] in item?.popup.background.borderWidth = $0 }
            case "glass":
                guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
                item.popup.background.glass = flag
                ctx.invalidate()
                return nil
            case "shadow", "image":
                // Panel shadow comes from the window; images unsupported. Ignore.
                return nil
            default:
                return "[?] unknown property: popup.background.\(rest.joined(separator: "."))"
            }
        default:
            return "[?] unknown property: popup.\(path.joined(separator: "."))"
        }
    }

    // MARK: - Closure-based animatable leaves (for state not reachable by key path)

    static func setFloatValue(key: String, current: Float, value: String,
                              ctx: PropertyContext, assign: @escaping (Float) -> Void) -> String? {
        guard let target = Float(value), target.isFinite else { return "[!] invalid number: \(value)" }
        if let animation = ctx.animation, animation.durationFrames > 0 {
            let invalidate = ctx.invalidate
            ctx.scheduler.animate(
                key: key, from: .float(current), to: .float(target),
                durationFrames: animation.durationFrames, curve: animation.curve
            ) { animValue in
                guard case .float(let now) = animValue else { return }
                assign(now)
                invalidate()
            }
        } else {
            ctx.scheduler.cancel(key: key)
            assign(target)
            ctx.invalidate()
        }
        return nil
    }

    static func setColorValue(key: String, current: YColor, value: String,
                              ctx: PropertyContext, assign: @escaping (YColor) -> Void) -> String? {
        guard let target = YColor.parse(value) else { return "[!] invalid color: \(value)" }
        if let animation = ctx.animation, animation.durationFrames > 0 {
            let invalidate = ctx.invalidate
            ctx.scheduler.animate(
                key: key, from: .color(current), to: .color(target),
                durationFrames: animation.durationFrames, curve: animation.curve
            ) { animValue in
                guard case .color(let now) = animValue else { return }
                assign(now)
                invalidate()
            }
        } else {
            ctx.scheduler.cancel(key: key)
            assign(target)
            ctx.invalidate()
        }
        return nil
    }

    // MARK: - Text sub-domain (icon.* / label.*)

    private static func setText(
        _ item: Item,
        _ base: ReferenceWritableKeyPath<Item, TextPart>,
        _ prefix: String,
        _ path: ArraySlice<Substring>,
        _ value: String,
        _ ctx: PropertyContext,
        isIcon: Bool = false
    ) -> String? {
        guard let head = path.first else {
            // Bare `icon=...` / `label=...` sets the string.
            item[keyPath: base.appending(path: \TextPart.string)] = value
            ctx.invalidate()
            return nil
        }
        let rest = path.dropFirst()
        switch head {
        case "string":
            item[keyPath: base.appending(path: \TextPart.string)] = value
            ctx.invalidate()
            return nil
        case "drawing":
            return setBool(item, base.appending(path: \TextPart.drawing), value, ctx)
        case "color":
            return setColor(item, base.appending(path: \TextPart.color), "\(prefix).color", rest, value, ctx)
        case "highlight":
            return setBool(item, base.appending(path: \TextPart.highlight), value, ctx)
        case "highlight_color":
            return setColor(item, base.appending(path: \TextPart.highlightColor),
                            "\(prefix).highlight_color", rest, value, ctx)
        case "font":
            return setFont(item, base.appending(path: \TextPart.font), "\(prefix).font", rest, value, ctx)
        case "padding_left":
            return setFloat(item, base.appending(path: \TextPart.paddingLeft),
                            "\(prefix).padding_left", value, ctx)
        case "padding_right":
            return setFloat(item, base.appending(path: \TextPart.paddingRight),
                            "\(prefix).padding_right", value, ctx)
        case "y_offset":
            return setFloat(item, base.appending(path: \TextPart.yOffset), "\(prefix).y_offset", value, ctx)
        case "scroll_duration":
            guard let frames = Int(value), frames > 0 else { return "[!] invalid scroll_duration: \(value)" }
            item[keyPath: base.appending(path: \TextPart.scrollDuration)] = frames
            return nil
        case "max_chars":
            guard let count = Int(value), count >= 0 else { return "[!] invalid max_chars: \(value)" }
            item[keyPath: base.appending(path: \TextPart.maxChars)] = count
            ctx.invalidate()
            return nil
        case "width":
            return setTextWidth(item, base, prefix, isIcon, value, ctx)
        case "align":
            guard let first = value.first, "lcr".contains(first) else { return "[!] invalid align: \(value)" }
            item[keyPath: base.appending(path: \TextPart.align)] = first
            ctx.invalidate()
            return nil
        case "scroll_duration":
            return nil
        case "background":
            return setBackground(item, base.appending(path: \TextPart.background),
                                 "\(prefix).background", rest, value, ctx)
        case "shadow":
            return setShadow(item, base.appending(path: \TextPart.shadow), "\(prefix).shadow", rest, value, ctx)
        default:
            return "[?] unknown property: \(prefix).\(path.joined(separator: "."))"
        }
    }

    private static func setFont(
        _ item: Item,
        _ base: ReferenceWritableKeyPath<Item, FontSpec>,
        _ prefix: String,
        _ path: ArraySlice<Substring>,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        guard let head = path.first else {
            var font = item[keyPath: base]
            font.apply(value)
            item[keyPath: base] = font
            ctx.invalidate()
            return nil
        }
        switch head {
        case "family":
            item[keyPath: base.appending(path: \FontSpec.family)] = value
            ctx.invalidate()
            return nil
        case "style":
            item[keyPath: base.appending(path: \FontSpec.style)] = value
            ctx.invalidate()
            return nil
        case "size":
            return setFloat(item, base.appending(path: \FontSpec.size), "\(prefix).size", value, ctx)
        case "features":
            return nil
        default:
            return "[?] unknown property: \(prefix).\(path.joined(separator: "."))"
        }
    }

    // MARK: - Background sub-domain

    private static func setBackground(
        _ item: Item,
        _ base: ReferenceWritableKeyPath<Item, BackgroundStyle>,
        _ prefix: String,
        _ path: ArraySlice<Substring>,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        guard let head = path.first else { return "[!] \(prefix) needs a sub-property" }
        let rest = path.dropFirst()
        switch head {
        case "drawing":
            return setBool(item, base.appending(path: \BackgroundStyle.drawing), value, ctx)
        case "image":
            switch rest.first {
            case nil, "string":
                item[keyPath: base.appending(path: \BackgroundStyle.imageSource)] = value
                item[keyPath: base.appending(path: \BackgroundStyle.drawing)] = true
            case "scale":
                guard let scale = Float(value), scale.isFinite, scale > 0 else { return "[!] invalid image.scale: \(value)" }
                item[keyPath: base.appending(path: \BackgroundStyle.imageScale)] = scale
            case "drawing":
                guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
                item[keyPath: base.appending(path: \BackgroundStyle.imageDrawing)] = flag
            default:
                return nil  // corner_radius/border sub-keys accepted (no-op v1)
            }
            ctx.invalidate()
            return nil
        case "clip":
            guard let clip = Float(value), clip.isFinite, clip >= 0 else { return "[!] invalid clip: \(value)" }
            item[keyPath: base.appending(path: \BackgroundStyle.clip)] = clip
            ctx.invalidate()
            return nil
        case "color":
            // sketchybar parity: setting a background color enables drawing.
            item[keyPath: base.appending(path: \BackgroundStyle.drawing)] = true
            return setColor(item, base.appending(path: \BackgroundStyle.color), "\(prefix).color", rest, value, ctx)
        case "border_color":
            return setColor(item, base.appending(path: \BackgroundStyle.borderColor),
                            "\(prefix).border_color", rest, value, ctx)
        case "border_width":
            return setFloat(item, base.appending(path: \BackgroundStyle.borderWidth),
                            "\(prefix).border_width", value, ctx)
        case "corner_radius":
            return setFloat(item, base.appending(path: \BackgroundStyle.cornerRadius),
                            "\(prefix).corner_radius", value, ctx)
        case "height":
            return setFloat(item, base.appending(path: \BackgroundStyle.height), "\(prefix).height", value, ctx)
        case "padding_left":
            return setFloat(item, base.appending(path: \BackgroundStyle.paddingLeft),
                            "\(prefix).padding_left", value, ctx)
        case "padding_right":
            return setFloat(item, base.appending(path: \BackgroundStyle.paddingRight),
                            "\(prefix).padding_right", value, ctx)
        case "x_offset":
            return setFloat(item, base.appending(path: \BackgroundStyle.xOffset), "\(prefix).x_offset", value, ctx)
        case "y_offset":
            return setFloat(item, base.appending(path: \BackgroundStyle.yOffset), "\(prefix).y_offset", value, ctx)
        case "glass":
            guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
            item[keyPath: base.appending(path: \BackgroundStyle.glass)] = flag
            ctx.invalidate()
            return nil
        case "image", "clip":
            // Background images / bar clipping are not in YBar v1; ignore quietly.
            return nil
        case "gradient_color":
            guard let color = YColor.parse(value) else { return "[!] invalid color: \(value)" }
            item[keyPath: base.appending(path: \BackgroundStyle.gradientColor)] = color
            item[keyPath: base.appending(path: \BackgroundStyle.drawing)] = true
            ctx.invalidate()
            return nil
        case "gradient_angle":
            return setFloat(item, base.appending(path: \BackgroundStyle.gradientAngle),
                            "\(prefix).gradient_angle", value, ctx)
        case "shadow":
            return setShadow(item, base.appending(path: \BackgroundStyle.shadow), "\(prefix).shadow",
                             rest, value, ctx)
        default:
            return "[?] unknown property: \(prefix).\(path.joined(separator: "."))"
        }
    }

    // MARK: - Shadow sub-domain

    private static func setShadow(
        _ item: Item,
        _ base: ReferenceWritableKeyPath<Item, ShadowStyle>,
        _ prefix: String,
        _ path: ArraySlice<Substring>,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        guard let head = path.first else {
            // Bare `shadow=on|off` toggles drawing (sketchybar shorthand).
            return setBool(item, base.appending(path: \ShadowStyle.drawing), value, ctx)
        }
        let rest = path.dropFirst()
        switch head {
        case "drawing":
            return setBool(item, base.appending(path: \ShadowStyle.drawing), value, ctx)
        case "color":
            return setColor(item, base.appending(path: \ShadowStyle.color), "\(prefix).color", rest, value, ctx)
        case "distance":
            return setFloat(item, base.appending(path: \ShadowStyle.distance), "\(prefix).distance", value, ctx)
        case "angle":
            return setFloat(item, base.appending(path: \ShadowStyle.angle), "\(prefix).angle", value, ctx)
        default:
            return "[?] unknown property: \(prefix).\(path.joined(separator: "."))"
        }
    }

    /// Text-part `width` with the same dynamic-sentinel resolution as item width.
    private static func setTextWidth(
        _ item: Item,
        _ base: ReferenceWritableKeyPath<Item, TextPart>,
        _ prefix: String,
        _ isIcon: Bool,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        let widthPath = base.appending(path: \TextPart.customWidth)
        let animationKey = "item.\(item.id).\(prefix).width"
        if value == "dynamic" {
            if let animation = ctx.animation, animation.durationFrames > 0,
               item[keyPath: widthPath] >= 0, let measure = ctx.measureTextNaturalWidth {
                let invalidate = ctx.invalidate
                ctx.scheduler.animate(
                    key: animationKey,
                    from: .float(item[keyPath: widthPath]),
                    to: .float(measure(item, isIcon)),
                    durationFrames: animation.durationFrames,
                    curve: animation.curve,
                    apply: { [weak item] animValue in
                        guard case .float(let current) = animValue else { return }
                        item?[keyPath: widthPath] = current
                        invalidate()
                    },
                    onComplete: { [weak item] in
                        item?[keyPath: widthPath] = -1
                        invalidate()
                    })
                return nil
            }
            ctx.scheduler.cancel(key: animationKey)
            item[keyPath: widthPath] = -1
            ctx.invalidate()
            return nil
        }
        guard let parsed = Float(value), parsed.isFinite else { return "[!] invalid number: \(value)" }
        if let animation = ctx.animation, animation.durationFrames > 0,
           item[keyPath: widthPath] < 0, let measure = ctx.measureTextNaturalWidth {
            item[keyPath: widthPath] = measure(item, isIcon)
        }
        return setFloat(item, widthPath, "\(prefix).width", value, ctx)
    }

    // MARK: - Width (dynamic sentinel handling)

    /// `width=<n>` is a plain animatable float; `width=dynamic` stores the -1
    /// sentinel. Under `--animate`, the sentinel is resolved to the measured
    /// natural width at both endpoints so the item never lerps toward -1
    /// (sketchybar's flagship width animation idiom).
    private static func setWidth(_ item: Item, _ value: String, _ ctx: PropertyContext) -> String? {
        let animationKey = "item.\(item.id).width"
        if value == "dynamic" {
            if let animation = ctx.animation, animation.durationFrames > 0,
               item.customWidth >= 0, let measure = ctx.measureNaturalWidth {
                let invalidate = ctx.invalidate
                ctx.scheduler.animate(
                    key: animationKey,
                    from: .float(item.customWidth),
                    to: .float(measure(item)),
                    durationFrames: animation.durationFrames,
                    curve: animation.curve,
                    apply: { [weak item] animValue in
                        guard case .float(let current) = animValue else { return }
                        item?.customWidth = current
                        invalidate()
                    },
                    onComplete: { [weak item] in
                        item?.customWidth = -1
                        invalidate()
                    })
                return nil
            }
            ctx.scheduler.cancel(key: animationKey)
            item.customWidth = -1
            ctx.invalidate()
            return nil
        }
        // Animating dynamic -> fixed: seed from the real rendered width, not -1
        // (validated first — a bad value must not freeze the dynamic sentinel).
        guard let parsed = Float(value), parsed.isFinite else { return "[!] invalid number: \(value)" }
        if let animation = ctx.animation, animation.durationFrames > 0,
           item.customWidth < 0, let measure = ctx.measureNaturalWidth {
            item.customWidth = measure(item)
        }
        return setFloat(item, \Item.customWidth, "width", value, ctx)
    }

    // MARK: - Leaf helpers

    /// Animatable float leaf.
    private static func setFloat(
        _ item: Item,
        _ keyPath: ReferenceWritableKeyPath<Item, Float>,
        _ key: String,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        guard let target = Float(value), target.isFinite else { return "[!] invalid number: \(value)" }
        let animationKey = "item.\(item.id).\(key)"
        if let animation = ctx.animation, animation.durationFrames > 0 {
            let invalidate = ctx.invalidate
            ctx.scheduler.animate(
                key: animationKey,
                from: .float(item[keyPath: keyPath]),
                to: .float(target),
                durationFrames: animation.durationFrames,
                curve: animation.curve
            ) { [weak item] animValue in
                guard case .float(let current) = animValue else { return }
                item?[keyPath: keyPath] = current
                invalidate()
            }
        } else {
            ctx.scheduler.cancel(key: animationKey)
            item[keyPath: keyPath] = target
            ctx.invalidate()
        }
        return nil
    }

    /// Animatable color leaf, with per-channel addressing (`...color.alpha` etc.).
    private static func setColor(
        _ item: Item,
        _ keyPath: ReferenceWritableKeyPath<Item, YColor>,
        _ key: String,
        _ path: ArraySlice<Substring>,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        if let channel = path.first {
            switch channel {
            case "alpha":
                return setFloat(item, keyPath.appending(path: \YColor.alpha), "\(key).alpha", value, ctx)
            case "red":
                return setFloat(item, keyPath.appending(path: \YColor.red), "\(key).red", value, ctx)
            case "green":
                return setFloat(item, keyPath.appending(path: \YColor.green), "\(key).green", value, ctx)
            case "blue":
                return setFloat(item, keyPath.appending(path: \YColor.blue), "\(key).blue", value, ctx)
            case "hex":
                break // fall through to whole-color parse below
            default:
                return "[?] unknown color channel: \(channel)"
            }
        }
        guard let target = YColor.parse(value) else { return "[!] invalid color: \(value)" }
        let animationKey = "item.\(item.id).\(key)"
        if let animation = ctx.animation, animation.durationFrames > 0 {
            let invalidate = ctx.invalidate
            ctx.scheduler.animate(
                key: animationKey,
                from: .color(item[keyPath: keyPath]),
                to: .color(target),
                durationFrames: animation.durationFrames,
                curve: animation.curve
            ) { [weak item] animValue in
                guard case .color(let current) = animValue else { return }
                item?[keyPath: keyPath] = current
                invalidate()
            }
        } else {
            ctx.scheduler.cancel(key: animationKey)
            item[keyPath: keyPath] = target
            ctx.invalidate()
        }
        return nil
    }

    private static func setBool(
        _ item: Item,
        _ keyPath: ReferenceWritableKeyPath<Item, Bool>,
        _ value: String,
        _ ctx: PropertyContext
    ) -> String? {
        if value == "toggle" {
            item[keyPath: keyPath].toggle()
            ctx.invalidate()
            return nil
        }
        guard let flag = parseBool(value) else { return "[!] invalid boolean: \(value)" }
        item[keyPath: keyPath] = flag
        ctx.invalidate()
        return nil
    }

    private static func setDisplayAssociation(_ item: Item, _ value: String, _ ctx: PropertyContext) -> String? {
        if value == "active" {
            item.associatedToActiveDisplay = true
            item.associatedDisplayMask = 0
            ctx.invalidate()
            return nil
        }
        var mask: UInt32 = 0
        for token in value.split(separator: ",") {
            guard let index = Int(token), index >= 1, index <= 32 else {
                return "[!] invalid display list: \(value)"
            }
            mask |= 1 << UInt32(index - 1)
        }
        item.associatedToActiveDisplay = false
        item.associatedDisplayMask = mask
        ctx.invalidate()
        return nil
    }

    /// sketchybar-compatible booleans: on/off, true/false, yes/no, 1/0.
    public static func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "on", "true", "yes", "1": return true
        case "off", "false", "no", "0": return false
        default: return nil
        }
    }
}
