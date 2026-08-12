#include "model/item.h"

#include <algorithm>
#include <cstdio>
#include <regex>

namespace ybar::model {

int Item::nextId = 1;

bool Item::isVisibleInFlow() const {
    if (!drawing) return false;
    return icon.drawing || label.drawing || background.drawing || customWidth >= 0 ||
           graph.has_value() || slider.has_value() || gauge.has_value() ||
           (image.has_value() && image->drawing);
}

namespace {

// "/pattern/" (len > 2, both slashes) -> unanchored regex; else exact match.
std::optional<std::regex> regexTarget(std::string_view target) {
    if (target.size() <= 2 || target.front() != '/' || target.back() != '/') return std::nullopt;
    const std::string pattern(target.substr(1, target.size() - 2));
    try {
        return std::regex(pattern, std::regex::ECMAScript);
    } catch (const std::regex_error&) {
        std::fprintf(stderr, "[ybar] invalid regex target: %.*s\n",
                     static_cast<int>(target.size()), target.data());
        return std::nullopt;
    }
}

bool isRegexForm(std::string_view target) {
    return target.size() > 2 && target.front() == '/' && target.back() == '/';
}

} // namespace

ItemStore::ItemStore() { resetDefaults(); }

void ItemStore::resetDefaults() {
    defaults_ = std::make_unique<Item>();
    defaults_->name = "defaults";
    defaults_->position = ItemPosition::Left;
}

void ItemStore::applyDefaults(Item& item) const {
    // Copies EXACTLY this list (reference contract) — nothing more.
    item.icon = defaults_->icon;
    item.label = defaults_->label;
    item.background = defaults_->background;
    item.paddingLeft = defaults_->paddingLeft;
    item.paddingRight = defaults_->paddingRight;
    item.yOffset = defaults_->yOffset;
    item.updatePolicy = defaults_->updatePolicy;
    item.script = defaults_->script;
    item.clickScript = defaults_->clickScript;
    item.updateFrequency = defaults_->updateFrequency;
    item.blurRadius = defaults_->blurRadius;
    item.customWidth = defaults_->customWidth;
    item.align = defaults_->align;
}

Item* ItemStore::add(const std::string& name, ItemPosition position, ItemKind kind) {
    if (name.empty() || find(name)) return nullptr;
    auto item = std::make_unique<Item>();
    item->name = name;
    item->position = position;
    item->kind = kind;
    applyDefaults(*item);
    items_.push_back(std::move(item));
    return items_.back().get();
}

Item* ItemStore::find(std::string_view name) {
    for (auto& item : items_)
        if (item->name == name) return item.get();
    return nullptr;
}

std::vector<Item*> ItemStore::matching(std::string_view target) {
    std::vector<Item*> result;
    if (isRegexForm(target)) {
        const auto regex = regexTarget(target);
        if (!regex) return result;
        for (auto& item : items_)
            if (std::regex_search(item->name, *regex)) result.push_back(item.get());
        return result;
    }
    if (auto* item = find(target)) result.push_back(item);
    return result;
}

bool ItemStore::remove(std::string_view target) {
    const auto matches = matching(target);
    if (matches.empty()) return false;
    for (auto* match : matches) {
        std::erase_if(items_, [&](const auto& item) { return item.get() == match; });
    }
    return true;
}

void ItemStore::removeAll() {
    items_.clear();
    resetDefaults();
}

bool ItemStore::move(std::string_view name, bool before, std::string_view anchor) {
    if (name == anchor) return false;
    std::size_t selfIdx = items_.size();
    std::size_t anchorIdx = items_.size();
    for (std::size_t i = 0; i < items_.size(); ++i) {
        if (items_[i]->name == name) selfIdx = i;
        if (items_[i]->name == anchor) anchorIdx = i;
    }
    if (selfIdx == items_.size() || anchorIdx == items_.size()) return false;
    auto moved = std::move(items_[selfIdx]);
    items_.erase(items_.begin() + static_cast<std::ptrdiff_t>(selfIdx));
    if (selfIdx < anchorIdx) --anchorIdx; // erase shifted the anchor left
    const std::size_t insertAt = before ? anchorIdx : anchorIdx + 1;
    items_.insert(items_.begin() + static_cast<std::ptrdiff_t>(insertAt), std::move(moved));
    return true;
}

bool ItemStore::reorder(const std::vector<std::string>& names) {
    // Listed items swap into each other's existing slots.
    std::vector<std::size_t> slots;
    for (const auto& name : names) {
        const auto it = std::find_if(items_.begin(), items_.end(),
                                     [&](const auto& i) { return i->name == name; });
        if (it == items_.end()) return false;
        const auto slot = static_cast<std::size_t>(std::distance(items_.begin(), it));
        if (std::find(slots.begin(), slots.end(), slot) != slots.end()) return false; // dup name
        slots.push_back(slot);
    }
    if (slots.size() != names.size()) return false;
    auto sorted = slots;
    std::sort(sorted.begin(), sorted.end());
    std::vector<std::unique_ptr<Item>> picked;
    picked.reserve(names.size());
    for (const auto& name : names) {
        const auto it = std::find_if(items_.begin(), items_.end(),
                                     [&](const auto& i) { return i && i->name == name; });
        picked.push_back(std::move(*it));
    }
    for (std::size_t k = 0; k < sorted.size(); ++k) items_[sorted[k]] = std::move(picked[k]);
    return true;
}

bool ItemStore::rename(std::string_view oldName, std::string_view newName) {
    if (newName.empty() || find(newName)) return false;
    auto* item = find(oldName);
    if (!item) return false;
    for (auto& other : items_) {
        for (auto& member : other->members)
            if (member == oldName) member = std::string(newName);
        if (other->popupHost == oldName) other->popupHost = std::string(newName);
    }
    item->name = std::string(newName);
    return true;
}

Item* ItemStore::clone(const std::string& newName, std::string_view source,
                       Placement placement) {
    auto* src = find(source);
    if (!src || newName.empty() || find(newName)) return nullptr;
    auto item = std::make_unique<Item>();
    item->name = newName;
    item->position = src->position;
    // kind is NOT copied: the reference clones through add(), so a cloned
    // bracket/graph becomes a plain item.
    // defaults-set fields plus the documented clone extras; components are
    // deliberately NOT copied (reference asymmetry).
    item->icon = src->icon;
    item->label = src->label;
    item->background = src->background;
    item->paddingLeft = src->paddingLeft;
    item->paddingRight = src->paddingRight;
    item->yOffset = src->yOffset;
    item->updatePolicy = src->updatePolicy;
    item->script = src->script;
    item->clickScript = src->clickScript;
    item->updateFrequency = src->updateFrequency;
    item->drawing = src->drawing;
    item->customWidth = src->customWidth;
    item->align = src->align;
    item->blurRadius = src->blurRadius;
    item->members = src->members;
    item->popupHost = src->popupHost;

    if (placement == Placement::Append) {
        items_.push_back(std::move(item));
        return items_.back().get();
    }
    auto anchor = std::find_if(items_.begin(), items_.end(),
                               [&](const auto& i) { return i->name == source; });
    const auto position = placement == Placement::Before ? anchor : std::next(anchor);
    return items_.insert(position, std::move(item))->get();
}

std::vector<Item*> ItemStore::expandMembers(const std::vector<std::string>& members) {
    std::vector<Item*> result;
    for (const auto& member : members) {
        for (auto* item : matching(member)) {
            const bool seen = std::any_of(result.begin(), result.end(),
                                          [&](Item* i) { return i->id == item->id; });
            if (!seen) result.push_back(item);
        }
    }
    return result;
}

} // namespace ybar::model
