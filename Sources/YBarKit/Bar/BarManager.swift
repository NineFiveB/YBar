import AppKit
import IOKit.pwr_mgt
import Metal

/// Weak hook registry so @Sendable system callbacks (global event monitors)
/// can reach main-actor state without capturing it.
@MainActor
final class DaemonHooks {
    static let shared = DaemonHooks()
    var closePopups: (() -> Void)?
    var reframeBars: (() -> Void)?
    /// Wired by the daemon: request Core Location auth for SSID resolution.
    var requestLocation: (() -> Void)?
}

/// Owns the bars: one surface per included display, the shared render stack,
/// layout, damage-driven redraw, and mouse routing. All mutation is main-actor.
@MainActor
public final class BarManager {
    public let store = ItemStore()
    public var settings = BarSettings() {
        didSet { applySettings() }
    }

    public let fontCache = FontCache()
    let device: MTLDevice
    let renderer: Renderer
    let sceneBuilder: SceneBuilder
    let displayManager = DisplayManager()

    public private(set) var surfaces: [BarSurface] = []
    private var popupSurfaces: [Int: PopupSurface] = [:]
    private var atlases: [CGFloat: GlyphAtlas] = [:]
    private var renderScheduled = false
    private var retryScheduled = false
    /// Item id of a slider currently being dragged.
    private var draggingSliderID: Int?
    private var outsideClickMonitor: Any?
    private var menuBarObserver: NSObjectProtocol?

    // Interaction hooks, wired by the daemon (scripts + event bus live there).
    public var onItemClicked: ((Item, MouseEventInfo) -> Void)?
    public var onItemHover: ((Item, _ entered: Bool) -> Void)?
    public var onItemScrolled: ((Item, _ delta: CGFloat, _ modifier: String) -> Void)?
    /// Fired after surfaces are rebuilt for a display topology change.
    public var onDisplaysChanged: (() -> Void)?
    /// Fired after ANY surface rebuild (topology or display-policy change) —
    /// the animation display link is bound to a surface view and must re-attach.
    public var onSurfacesRebuilt: (() -> Void)?
    /// A slider drag ended at the given percentage.
    public var onSliderChanged: ((Item, Float) -> Void)?
    /// A slider drag began (the daemon cancels in-flight percentage animations).
    public var onSliderDragStarted: ((Item) -> Void)?
    /// The pointer left every YBar window (bar + popups) — `mouse.exited.global`.
    public var onGlobalMouseExit: (() -> Void)?
    /// The pointer entered a YBar window while previously inside none.
    public var onGlobalMouseEnter: (() -> Void)?
    /// The last built scene contains marquee text (drives the display link).
    public var onMarqueeDemand: ((Bool) -> Void)?
    /// Waybar idle_inhibitor analogue: a power-management assertion that
    /// keeps the display awake while active.
    private var idleAssertion: IOPMAssertionID = 0

    public func setIdleInhibit(_ active: Bool) {
        guard active != settings.idleInhibit else { return }
        settings.idleInhibit = active
        if active {
            var id = IOPMAssertionID(0)
            let ok = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "ybar idle inhibitor" as CFString, &id)
            if ok == kIOReturnSuccess { idleAssertion = id }
        } else if idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = 0
        }
    }
    private var pointerInsideSurfaces = Set<ObjectIdentifier>()

    public init() throws {
        guard let metalDevice = MTLCreateSystemDefaultDevice() else {
            throw Renderer.RendererError.noDevice
        }
        device = metalDevice
        renderer = try Renderer(device: metalDevice)
        sceneBuilder = SceneBuilder(fontCache: fontCache)
    }

    public func begin() {
        displayManager.start()
        displayManager.onChange = { [weak self] in
            self?.rebuildSurfaces()
            self?.onDisplaysChanged?()
        }
        // Menu-bar autohide toggles move the bar between the top strip and
        // below-the-strip (sketchybar listens for exactly this notification).
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceMenuBarHidingChangedNotification"),
            object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                DaemonHooks.shared.reframeBars?()
            }
        }
        menuBarObserver = observer
        DaemonHooks.shared.reframeBars = { [weak self] in
            guard let self else { return }
            let screens = DisplayManager.screens()
            for surface in self.surfaces {
                if let entry = screens.first(where: { $0.index == surface.arrangementIndex }) {
                    surface.apply(settings: self.settings, screen: entry.screen)
                }
            }
            self.setNeedsRender()
        }
        rebuildSurfaces()
    }

    /// fullscreen_show: raise each surface over the active Space's fullscreen
    /// window, or restore its configured level. Called on active-space changes
    /// (Daemon) and when the property toggles.
    public func updateFullscreenElevation() {
        for surface in surfaces {
            let raise = settings.fullscreenShow
                && BarManager.hasFullscreenWindow(on: surface.screen)
            surface.setElevated(raise, settings: settings)
        }
    }

    /// A fullscreen Space is fronted by a layer-0 window covering the screen
    /// frame — either fully, or minus the reserved camera-housing strip on
    /// notched displays (safeAreaInsets.top + 1pt separator), which is where
    /// apps that don't draw under the notch are laid out.
    static func hasFullscreenWindow(on screen: NSScreen) -> Bool {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let frame = screen.frame
        // CG global coordinates share x with AppKit; y counts down from the
        // primary screen's top edge. Matching y too keeps a fullscreen window
        // on one display from elevating bars on same-sized siblings.
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        let expectedY = primaryMaxY - frame.maxY
        let notchInset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top + 1 : 0
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            guard abs((bounds["X"] ?? 0) - frame.minX) < 1,
                  abs((bounds["Width"] ?? 0) - frame.width) < 1 else { continue }
            let y = bounds["Y"] ?? 0
            let height = bounds["Height"] ?? 0
            let fullFrame = abs(height - frame.height) < 1 && abs(y - expectedY) < 1
            let belowNotch = notchInset > 0
                && abs(height - (frame.height - notchInset)) < 2
                && abs(y - (expectedY + notchInset)) < 2
            if fullFrame || belowNotch { return true }
        }
        return false
    }

    public func shutdown() {
        displayManager.stop()
        surfaces.forEach { $0.close() }
        surfaces.removeAll()
        popupSurfaces.values.forEach { $0.close() }
        popupSurfaces.removeAll()
    }

    // MARK: - Surfaces

    public func rebuildSurfaces() {
        // Closed panels never deliver mouseExited — clean the presence set or
        // mouse.exited.global dies for the session after a display change.
        let hadPointer = surfaces.contains { pointerInsideSurfaces.contains(ObjectIdentifier($0)) }
        surfaces.forEach { pointerInsideSurfaces.remove(ObjectIdentifier($0)) }
        if hadPointer { scheduleGlobalExitCheck() }
        surfaces.forEach { $0.close() }
        surfaces.removeAll()

        for (index, screen) in DisplayManager.screens() {
            guard settings.includesDisplay(arrangementIndex: index, isMain: index == 1) else { continue }
            let surface = BarSurface(screen: screen, arrangementIndex: index)
            surface.hostView.metalLayer.device = device
            surface.onMouse = { [weak self] info, surface in
                self?.handleMouse(info, on: surface)
            }
            surface.apply(settings: settings, screen: screen)
            surfaces.append(surface)
        }
        onSurfacesRebuilt?()
        // Fresh surfaces start un-elevated; re-evaluate or a bar rebuilt
        // while on a fullscreen Space (monitor hot-plug) stays buried.
        updateFullscreenElevation()
        setNeedsRender()
    }

    private func applySettings() {
        // Display policy changes require a rebuild; everything else is a re-frame.
        let expected = DisplayManager.screens()
            .filter { settings.includesDisplay(arrangementIndex: $0.index, isMain: $0.index == 1) }
            .map(\.index)
        if expected != surfaces.map(\.arrangementIndex) {
            rebuildSurfaces()
            return
        }
        let screens = DisplayManager.screens()
        for surface in surfaces {
            if let entry = screens.first(where: { $0.index == surface.arrangementIndex }) {
                surface.apply(settings: settings, screen: entry.screen)
            }
        }
        setNeedsRender()
    }

    // MARK: - Rendering

    /// Coalesced damage-driven redraw: any model change calls this; one frame
    /// renders on the next main-queue turn. No animation → zero further GPU work.
    public func setNeedsRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            self.renderAll()
        }
    }

    public func renderAll() {
        for surface in surfaces {
            render(surface: surface)
        }
        updatePopups()
    }

    // MARK: - Popups

    private func updatePopups() {
        // A host only counts as live once its scene actually rendered; anything
        // else (closed, hostless, empty, zero-size) tears its panel down —
        // stale, still-clickable panels must never linger.
        var liveHostIDs: Set<Int> = []
        for host in store.items where host.popup.isOpen {
            let members = store.items.filter { $0.position == .popup && $0.popupHost == host.name }
            guard !members.isEmpty,
                  let surface = surfaces.first(where: { surface in
                      surface.itemFrames.contains { $0.itemID == host.id && $0.frame != .zero }
                  }),
                  let hostFrame = surface.itemFrames.first(where: { $0.itemID == host.id })?.frame,
                  let atlas = atlas(for: surface.scale)
            else { continue }

            // The popup lives on the host's screen — build scene, atlas, and
            // drawable at that one scale (a fresh panel's backingScaleFactor
            // reports the primary screen until it is ordered in).
            let scale = surface.scale
            let scene = sceneBuilder.buildPopup(
                host: host, members: members, scale: scale, atlas: atlas)
            guard scene.sizePoints.width > 0, scene.sizePoints.height > 0 else { continue }

            let popupSurface: PopupSurface
            if let existing = popupSurfaces[host.id] {
                popupSurface = existing
            } else {
                popupSurface = PopupSurface(hostItemID: host.id, device: device)
                popupSurface.onMouse = { [weak self] info, popup in
                    self?.handlePopupMouse(info, on: popup)
                }
                popupSurface.hostView.onBackingChanged = { [weak self] in
                    self?.setNeedsRender()
                }
                popupSurfaces[host.id] = popupSurface
            }
            popupSurface.itemFrames = scene.itemFrames

            // Host frame (bar-local, y-down) -> global AppKit coords (y-up).
            let barFrame = surface.panelFrame
            let anchor = CGRect(
                x: barFrame.minX + hostFrame.minX,
                y: barFrame.maxY - hostFrame.maxY,
                width: hostFrame.width,
                height: hostFrame.height)
            popupSurface.setGlass(
                enabled: host.popup.blurRadius > 0,
                cornerRadius: CGFloat(host.popup.background.cornerRadius))
            popupSurface.present(
                anchor: anchor,
                size: scene.sizePoints,
                barPosition: settings.position,
                yOffset: CGFloat(host.popup.yOffset),
                align: host.popup.align)
            if renderer.render(list: scene.list, layer: popupSurface.hostView.metalLayer, atlas: atlas) {
                liveHostIDs.insert(host.id)
            } else {
                scheduleRetry()
            }
        }

        for (hostID, popupSurface) in popupSurfaces where !liveHostIDs.contains(hostID) {
            if pointerInsideSurfaces.remove(ObjectIdentifier(popupSurface)) != nil {
                scheduleGlobalExitCheck()
            }
            popupSurface.close()
            popupSurfaces.removeValue(forKey: hostID)
        }
        updateOutsideClickMonitor()
    }

    private func handlePopupMouse(_ info: MouseEventInfo, on popup: PopupSurface) {
        func member(at point: CGPoint) -> Item? {
            guard let itemID = popup.itemFrames.first(where: { $0.frame.contains(point) })?.itemID
            else { return nil }
            return store.items.first { $0.id == itemID }
        }
        switch info.kind {
        case .clicked:
            if let item = member(at: info.point) {
                onItemClicked?(item, info)
            }
        case .moved:
            noteSurfaceEntered(ObjectIdentifier(popup))
            let hovered = member(at: info.point)
            guard popup.hoveredItemID != hovered?.id else { return }
            if let previousID = popup.hoveredItemID,
               let previous = store.items.first(where: { $0.id == previousID }) {
                previous.mouseOver = false
                onItemHover?(previous, false)
            }
            popup.hoveredItemID = hovered?.id
            if let hovered {
                hovered.mouseOver = true
                onItemHover?(hovered, true)
            }
        case .exited:
            pointerInsideSurfaces.remove(ObjectIdentifier(popup))
            if let previousID = popup.hoveredItemID,
               let previous = store.items.first(where: { $0.id == previousID }) {
                previous.mouseOver = false
                onItemHover?(previous, false)
            }
            popup.hoveredItemID = nil
            scheduleGlobalExitCheck()
        default:
            break
        }
    }

    // MARK: - Popup auto-close

    /// Clicks outside any YBar window close auto-close popups (global monitors
    /// observe other apps' mouse events; no permissions for mouse-only).
    private func updateOutsideClickMonitor() {
        let wantsMonitor = store.items.contains { $0.popup.isOpen && $0.popup.autoClose }
        if wantsMonitor, outsideClickMonitor == nil {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { _ in
                MainActor.assumeIsolated {
                    DaemonHooks.shared.closePopups?()
                }
            }
            DaemonHooks.shared.closePopups = { [weak self] in
                self?.closeAutoClosePopups(except: nil)
            }
        } else if !wantsMonitor, let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    public func closeAutoClosePopups(except exceptItemID: Int?) {
        var changed = false
        for item in store.items
        where item.popup.isOpen && item.popup.autoClose && item.id != exceptItemID {
            item.popup.isOpen = false
            changed = true
        }
        if changed { setNeedsRender() }
    }

    private func atlas(for scale: CGFloat) -> GlyphAtlas? {
        if let existing = atlases[scale] { return existing }
        guard let created = GlyphAtlas(device: device, scale: scale) else { return nil }
        atlases[scale] = created
        return created
    }

    private func render(surface: BarSurface) {
        let barSize = surface.barSize
        guard barSize.width > 0, barSize.height > 0 else { return }
        let scale = surface.scale
        guard let atlas = atlas(for: scale) else { return }

        let items = visibleItems(on: surface)
        // q/e dead zone only where a notch physically exists; notch_width=0
        // auto-detects the housing width on that screen.
        let notchWidth: CGFloat
        if surface.screen.safeAreaInsets.top > 0 {
            notchWidth = settings.notchWidth > 0
                ? CGFloat(settings.notchWidth)
                : BarSurface.physicalNotchWidth(of: surface.screen)
        } else {
            notchWidth = 0
        }
        let result = Layout.perform(items: items, barSize: barSize, settings: settings,
                                    notchWidth: notchWidth) { [fontCache] item in
            MeasuredContent(
                iconSize: fontCache.measure(part: item.icon),
                labelSize: fontCache.measure(part: item.label))
        }
        // Brackets derive frames from their members — resolved before the hit
        // snapshot so they are clickable/hoverable and can host popups.
        let bracketFrames = ComponentGeometry.bracketFrames(
            items: items, contentBoxes: result.contentBoxes, barHeight: barSize.height)
        for (itemID, frame) in bracketFrames {
            items.first { $0.id == itemID }?.frame = frame
        }
        surface.itemFrames = items.map { ($0.id, $0.frame) }

        // Glass backdrops: blurred material views placed exactly under the
        // painted pill of every glass item (background.glass implies the
        // backdrop; blur_radius > 0 forces one explicitly).
        var glassSpecs: [(itemID: Int, rect: CGRect, cornerRadius: CGFloat)] = []
        for item in items
        where (item.blurRadius > 0
               || (item.background.glass && item.background.drawing
                   && item.background.color.alpha > 0.02))
            && item.isVisible {
            let rect: CGRect
            if item.kind == .bracket {
                // Bracket pill rect mirrors the SceneBuilder bracket pass.
                guard item.frame != .zero else { continue }
                let height = item.background.height > 0
                    ? CGFloat(item.background.height)
                    : barSize.height - 4
                rect = CGRect(
                    x: item.frame.minX + CGFloat(item.background.xOffset),
                    y: barSize.height / 2 - height / 2
                        - CGFloat(item.yOffset) - CGFloat(item.background.yOffset),
                    width: item.frame.width,
                    height: height)
            } else {
                guard let contentBox = result.contentBoxes[item.id], contentBox.width > 0 else { continue }
                let contentHeight = max(
                    fontCache.measure(part: item.icon).height,
                    fontCache.measure(part: item.label).height)
                rect = SceneBuilder.backgroundRect(
                    item: item, contentBox: contentBox, contentHeight: contentHeight)
            }
            glassSpecs.append((item.id, rect, CGFloat(item.background.cornerRadius)))
        }
        surface.syncGlassBackdrops(glassSpecs)

        sceneBuilder.clock = CACurrentMediaTime()
        let list = sceneBuilder.build(
            items: items,
            settings: settings,
            contentBoxes: result.contentBoxes,
            barSize: barSize,
            scale: scale,
            atlas: atlas)
        // Marquee text needs continuous frames; everything else stays
        // damage-driven.
        onMarqueeDemand?(sceneBuilder.sceneHasMarquee)
        if !renderer.render(list: list, layer: surface.hostView.metalLayer, atlas: atlas) {
            // Frame lost (display asleep / drawables exhausted): the damage flag
            // was already consumed, so reschedule or the update is never shown.
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.setNeedsRender()
        }
    }

    /// Measured natural content width of an item (used by `width=dynamic` animations).
    public func naturalWidth(of item: Item) -> Float {
        let measured = MeasuredContent(
            iconSize: fontCache.measure(part: item.icon),
            labelSize: fontCache.measure(part: item.label))
        return Float(Layout.naturalLength(item: item, measured: measured))
    }

    /// Natural SLOT width of one text part — ink plus its paddings, because a
    /// fixed customWidth replaces all three (`width=dynamic` animation endpoint).
    public func naturalTextWidth(of item: Item, icon: Bool) -> Float {
        let part = icon ? item.icon : item.label
        return Float(fontCache.naturalMeasure(part: part).width)
            + part.paddingLeft + part.paddingRight
    }

    /// Items associated with a surface's display (mask bit i-1 = display i; 0 = all).
    /// `display=active` items appear only on the screen holding keyboard focus
    /// (public-API approximation of sketchybar's active-display tracking).
    public func visibleItems(on surface: BarSurface) -> [Item] {
        let activeScreen = NSScreen.main
        return store.items.filter { item in
            if item.associatedToActiveDisplay {
                return surface.screen == activeScreen
            }
            return item.associatedDisplayMask == 0
                || item.associatedDisplayMask & (1 << UInt32(surface.arrangementIndex - 1)) != 0
        }
    }

    /// Per-display hit frames for `--query` (`"display-N"` keyed, bar-local points).
    public func boundingRects(for item: Item) -> [String: [String: Any]] {
        var rects: [String: [String: Any]] = [:]
        for surface in surfaces {
            guard let frame = surface.itemFrames.first(where: { $0.itemID == item.id })?.frame,
                  frame != .zero else { continue }
            rects["display-\(surface.arrangementIndex)"] = [
                "origin": [frame.origin.x, frame.origin.y],
                "size": [frame.size.width, frame.size.height],
            ]
        }
        return rects
    }

    // MARK: - Mouse

    private func handleMouse(_ info: MouseEventInfo, on surface: BarSurface) {
        switch info.kind {
        case .down:
            let hit = hitTest(point: info.point, on: surface)
            // A press anywhere that is not an open popup's host dismisses
            // auto-close popups (host presses defer to their toggle scripts).
            closeAutoClosePopups(except: hit?.id)
            if let item = hit, item.slider != nil {
                draggingSliderID = item.id
                onSliderDragStarted?(item)
                updateSlider(item: item, localX: info.point.x, on: surface)
            }
        case .dragged:
            if let id = draggingSliderID,
               let item = store.items.first(where: { $0.id == id }) {
                item.slider?.isDragged = true
                updateSlider(item: item, localX: info.point.x, on: surface)
            }
        case .clicked:
            if let id = draggingSliderID,
               let item = store.items.first(where: { $0.id == id }),
               let slider = item.slider {
                draggingSliderID = nil
                slider.isDragged = false
                updateSlider(item: item, localX: info.point.x, on: surface)
                onSliderChanged?(item, slider.percentage)
                return
            }
            if let item = hitTest(point: info.point, on: surface) {
                onItemClicked?(item, info)
            }
        case .scrolled:
            if let item = hitTest(point: info.point, on: surface) {
                onItemScrolled?(item, info.scrollDelta, info.modifier)
            }
        case .moved:
            noteSurfaceEntered(ObjectIdentifier(surface))
            let hovered = hitTest(point: info.point, on: surface)
            updateHover(surface: surface, to: hovered)
        case .exited:
            pointerInsideSurfaces.remove(ObjectIdentifier(surface))
            updateHover(surface: surface, to: nil)
            scheduleGlobalExitCheck()
        }
    }

    private func noteSurfaceEntered(_ id: ObjectIdentifier) {
        let wasEmpty = pointerInsideSurfaces.isEmpty
        pointerInsideSurfaces.insert(id)
        if wasEmpty { onGlobalMouseEnter?() }
    }

    /// Debounced: crossing from the bar into its popup must not fire a global
    /// exit — only the pointer leaving every YBar window does.
    private func scheduleGlobalExitCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.pointerInsideSurfaces.isEmpty else { return }
            self.onGlobalMouseExit?()
        }
    }

    /// Map a bar-local x to the slider's percentage. Uses the event surface's
    /// own frame snapshot (the shared Item.frame holds whichever surface
    /// rendered last — wrong on multi-display) and mirrors the emit-side
    /// fixed-width alignment slack.
    private func updateSlider(item: Item, localX: CGFloat, on surface: BarSurface) {
        guard let slider = item.slider,
              let frame = surface.itemFrames.first(where: { $0.itemID == item.id })?.frame,
              frame != .zero
        else { return }
        var trackX = frame.minX + CGFloat(item.paddingLeft)
        if item.customWidth >= 0 {
            let slack = max(0, CGFloat(item.customWidth) - CGFloat(naturalWidth(of: item)))
            switch item.align {
            case "c": trackX += slack / 2
            case "r": trackX += slack
            default: break
            }
        }
        if item.icon.drawing, !item.icon.string.isEmpty {
            trackX += CGFloat(item.icon.paddingLeft)
                + fontCache.measure(part: item.icon).width
                + CGFloat(item.icon.paddingRight)
        }
        slider.percentage = slider.percentage(forLocalX: localX - trackX)
        setNeedsRender()
    }

    private func updateHover(surface: BarSurface, to item: Item?) {
        guard surface.hoveredItemID != item?.id else { return }
        if let previousID = surface.hoveredItemID,
           let previous = store.items.first(where: { $0.id == previousID }) {
            previous.mouseOver = false
            onItemHover?(previous, false)
        }
        surface.hoveredItemID = item?.id
        if let item {
            item.mouseOver = true
            onItemHover?(item, true)
        }
        updateTooltip(for: item, on: surface)
    }

    // MARK: - Tooltips (Waybar analogue: hover text bubble after a delay)

    private var tooltipSurface: PopupSurface?
    private var tooltipWork: DispatchWorkItem?

    private func updateTooltip(for item: Item?, on surface: BarSurface) {
        tooltipWork?.cancel()
        tooltipWork = nil
        hideTooltip()
        guard let item, !item.tooltip.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.showTooltip(for: item, on: surface)
        }
        tooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func showTooltip(for item: Item, on surface: BarSurface) {
        guard surface.hoveredItemID == item.id,
              let frame = surface.itemFrames.first(where: { $0.itemID == item.id })?.frame,
              let atlas = atlas(for: surface.scale) else { return }
        let built = sceneBuilder.buildTooltip(
            text: item.tooltip, scale: surface.scale, atlas: atlas)
        let tooltip = tooltipSurface ?? PopupSurface(hostItemID: -1, device: device)
        tooltipSurface = tooltip
        tooltip.panel.hasShadow = false
        let barFrame = surface.panelFrame
        let anchor = CGRect(
            x: barFrame.minX + frame.minX,
            y: barFrame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height)
        tooltip.present(anchor: anchor, size: built.sizePoints,
                        barPosition: settings.position, yOffset: 4, align: "c")
        _ = renderer.render(list: built.list, layer: tooltip.hostView.metalLayer, atlas: atlas)
    }

    public func hideTooltip() {
        tooltipSurface?.close()
    }

    public func hitTest(point: CGPoint, on surface: BarSurface) -> Item? {
        // Members take precedence over the bracket spanning them (sketchybar's
        // window z-order, expressed as a two-pass hit test).
        var bracketHit: Item?
        for (itemID, frame) in surface.itemFrames.reversed() where frame.contains(point) {
            guard let item = store.items.first(where: { $0.id == itemID }) else { continue }
            if item.kind == .bracket {
                if bracketHit == nil { bracketHit = item }
            } else {
                return item
            }
        }
        return bracketHit
    }
}
