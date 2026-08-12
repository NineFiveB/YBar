// The item model and store (spec sections 3.3, 8). All mutation happens on
// the UI thread — no internal locking, mirroring the reference @MainActor
// model.

#pragma once

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "model/components.h"
#include "model/geometry.h"
#include "model/style.h"

namespace ybar::model {

enum class ItemKind { Item, Bracket, Graph, Slider, Alias };

struct Item {
    int id = nextId++;
    std::string name;
    ItemKind kind = ItemKind::Item;
    ItemPosition position = ItemPosition::Left;
    std::string popupHost; // set when position == Popup

    bool drawing = true;
    std::string script;
    std::string clickScript;
    int updateFrequency = 0;
    int routineCounter = 0;
    UpdatePolicy updatePolicy = UpdatePolicy::On;
    std::uint64_t updateMask = 0;

    double paddingLeft = 0;
    double paddingRight = 0;
    double yOffset = 0;
    double customWidth = -1; // -1 = dynamic
    char align = 'c';
    double blurRadius = 0;
    bool scrollTexts = false;
    std::string tooltip;

    TextPart icon;
    TextPart label;
    BackgroundStyle background;

    std::vector<std::string> members; // bracket member names or /regex/ patterns

    std::optional<GraphState> graph;
    std::optional<SliderState> slider;
    std::optional<GaugeState> gauge;
    std::optional<ImageState> image;
    PopupState popup;

    std::uint32_t associatedDisplayMask = 0; // bit i-1 = display i; 0 = all
    bool associatedToActiveDisplay = false;

    bool mouseOver = false;
    bool hasLuaHandlers = false;

    Rect frame; // full interactive extent, written by layout

    // Occupies layout space? (spec: VISIBILITY rule)
    bool isVisibleInFlow() const;

    static int nextId;
};

class ItemStore {
public:
    ItemStore();

    // nullptr when the name is taken. Applies the defaults prototype.
    Item* add(const std::string& name, ItemPosition position, ItemKind kind = ItemKind::Item);
    Item* find(std::string_view name);
    const std::vector<std::unique_ptr<Item>>& items() const { return items_; }

    // Exact name, or unanchored /regex/ target (spec: ITEM TARGETING).
    std::vector<Item*> matching(std::string_view target);

    bool remove(std::string_view target); // exact or /regex/; false if nothing matched
    void removeAll();                     // also resets defaults

    bool move(std::string_view name, bool before, std::string_view anchor);
    bool reorder(const std::vector<std::string>& names);
    bool rename(std::string_view oldName, std::string_view newName);

    // Append = end of the list (the 2-arg --clone form); Before/After place
    // the copy adjacent to the source.
    enum class Placement { Append, Before, After };
    Item* clone(const std::string& newName, std::string_view source, Placement placement);

    Item& defaults() { return *defaults_; }
    void resetDefaults();
    void applyDefaults(Item& item) const;

    // Order-preserving, de-duplicated bracket member expansion.
    std::vector<Item*> expandMembers(const std::vector<std::string>& members);

private:
    std::vector<std::unique_ptr<Item>> items_;
    std::unique_ptr<Item> defaults_;
};

} // namespace ybar::model
