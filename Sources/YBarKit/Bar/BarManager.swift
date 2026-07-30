import AppKit
import Metal

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
    private var atlases: [CGFloat: GlyphAtlas] = [:]
    private var renderScheduled = false
    private var retryScheduled = false

    // Interaction hooks, wired by the daemon (scripts + event bus live there).
    public var onItemClicked: ((Item, MouseEventInfo) -> Void)?
    public var onItemHover: ((Item, _ entered: Bool) -> Void)?
    public var onItemScrolled: ((Item, _ delta: CGFloat, _ modifier: String) -> Void)?
    /// Fired after surfaces are rebuilt for a display topology change.
    public var onDisplaysChanged: (() -> Void)?
    /// Fired after ANY surface rebuild (topology or display-policy change) —
    /// the animation display link is bound to a surface view and must re-attach.
    public var onSurfacesRebuilt: (() -> Void)?

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
        rebuildSurfaces()
    }

    public func shutdown() {
        displayManager.stop()
        surfaces.forEach { $0.close() }
        surfaces.removeAll()
    }

    // MARK: - Surfaces

    public func rebuildSurfaces() {
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
    }

    private func render(surface: BarSurface) {
        let barSize = surface.barSize
        guard barSize.width > 0, barSize.height > 0 else { return }
        let scale = surface.scale

        let atlas: GlyphAtlas
        if let existing = atlases[scale] {
            atlas = existing
        } else if let created = GlyphAtlas(device: device, scale: scale) {
            atlases[scale] = created
            atlas = created
        } else {
            return
        }

        let items = visibleItems(on: surface)
        let result = Layout.perform(items: items, barSize: barSize, settings: settings) { [fontCache] item in
            MeasuredContent(
                iconSize: fontCache.measure(part: item.icon),
                labelSize: fontCache.measure(part: item.label))
        }
        surface.itemFrames = items.map { ($0.id, $0.frame) }

        let list = sceneBuilder.build(
            items: items,
            settings: settings,
            contentBoxes: result.contentBoxes,
            barSize: barSize,
            scale: scale,
            atlas: atlas)
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
        case .clicked:
            if let item = hitTest(point: info.point, on: surface) {
                onItemClicked?(item, info)
            }
        case .scrolled:
            if let item = hitTest(point: info.point, on: surface) {
                onItemScrolled?(item, info.scrollDelta, info.modifier)
            }
        case .moved:
            let hovered = hitTest(point: info.point, on: surface)
            updateHover(surface: surface, to: hovered)
        case .exited:
            updateHover(surface: surface, to: nil)
        }
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
    }

    public func hitTest(point: CGPoint, on surface: BarSurface) -> Item? {
        for (itemID, frame) in surface.itemFrames.reversed() where frame.contains(point) {
            return store.items.first { $0.id == itemID }
        }
        return nil
    }
}
