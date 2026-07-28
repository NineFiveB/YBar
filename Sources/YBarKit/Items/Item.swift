import AppKit

/// A live bar item: the unit of composition, mutable at runtime over IPC.
/// Composition mirrors sketchybar: background + icon(text) + label(text).
@MainActor
public final class Item {
    public let id: Int
    public var name: String
    public var position: ItemPosition

    public var drawing: Bool = true
    public var icon = TextPart()
    public var label = TextPart()
    public var background = BackgroundStyle()

    /// Fixed width override (-1 = dynamic width from content).
    public var customWidth: Float = -1
    /// Content alignment within a fixed-width item.
    public var align: Character = "c"
    public var yOffset: Float = 0
    /// Item-level paddings are outer margins around the whole item.
    public var paddingLeft: Float = 0
    public var paddingRight: Float = 0

    // Scripting / events
    public var script: String = ""
    public var clickScript: String = ""
    public var updateFrequency: Int = 0
    public var updatePolicy: UpdatePolicy = .on
    public var updateMask: UInt64 = 0
    public var routineCounter: Int = 0

    // Association
    /// Bitmask of display arrangement indices (bit i = display i+1); 0 = all displays.
    public var associatedDisplayMask: UInt32 = 0
    public var associatedToActiveDisplay: Bool = false

    // Interaction state
    public var mouseOver: Bool = false

    /// Frame within the bar, set by layout (bar-local, top-left origin, points).
    public var frame: CGRect = .zero

    private static var nextID = 0

    public init(name: String, position: ItemPosition) {
        self.id = Item.nextID
        Item.nextID += 1
        self.name = name
        self.position = position
    }

    /// Copy value-typed style/scripting fields from the prototype item
    /// (`--default` uses a hidden prototype so it shares the property parser —
    /// sketchybar's default_item design with value semantics instead of memcpy).
    public func applyDefaults(from prototype: Item) {
        icon = prototype.icon
        label = prototype.label
        background = prototype.background
        paddingLeft = prototype.paddingLeft
        paddingRight = prototype.paddingRight
        yOffset = prototype.yOffset
        updatePolicy = prototype.updatePolicy
        script = prototype.script
        clickScript = prototype.clickScript
        updateFrequency = prototype.updateFrequency
    }

    public var isVisible: Bool {
        drawing && (icon.drawing && !icon.string.isEmpty || label.drawing && !label.string.isEmpty
                    || background.drawing || customWidth >= 0)
    }
}

/// Ordered collection of items plus the defaults prototype.
@MainActor
public final class ItemStore {
    public private(set) var items: [Item] = []
    /// Hidden prototype configured by `--default` and copied into new items.
    public private(set) var defaults = Item(name: "defaults", position: .left)

    public init() {}

    public func resetDefaults() {
        defaults = Item(name: "defaults", position: .left)
    }

    public func item(named name: String) -> Item? {
        items.first { $0.name == name }
    }

    /// Add an item; returns nil if the name is already taken.
    @discardableResult
    public func add(name: String, position: ItemPosition) -> Item? {
        guard item(named: name) == nil else { return nil }
        let item = Item(name: name, position: position)
        item.applyDefaults(from: defaults)
        items.append(item)
        return item
    }

    public func remove(name: String) -> Bool {
        guard let index = items.firstIndex(where: { $0.name == name }) else { return false }
        items.remove(at: index)
        return true
    }

    public func removeAll() {
        items.removeAll()
        resetDefaults()
    }

    /// Items in registration order for one position slot.
    public func items(at position: ItemPosition) -> [Item] {
        items.filter { $0.position == position }
    }
}
