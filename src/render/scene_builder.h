// Items + layout boxes -> flat paint-ordered DisplayList in DEVICE PIXELS
// (spec sections 3.9, 7). This slice covers: bar background, item
// backgrounds, icon/label text. Components (graphs/sliders/gauges/images),
// clip holes, marquee, and popups land in the next slice.

#pragma once

#include <unordered_map>

#include "model/bar_settings.h"
#include "model/item.h"
#include "model/layout.h"
#include "render/font_cache.h"
#include "render/glyph_atlas.h"
#include "render/instances.h"

namespace ybar::render {

struct SceneParams {
    double barWidth = 0; // logical points
    double barHeight = 0;
    double scale = 1.0;
    double clock = 0; // monotonic seconds, drives marquee phase
};

DisplayList buildScene(const std::vector<std::unique_ptr<ybar::model::Item>>& items,
                       const std::unordered_map<int, ybar::model::Rect>& contentBoxes,
                       const ybar::model::BarSettings& settings, const SceneParams& params,
                       FontCache& fonts, GlyphAtlas& atlas);

// One item's full emission (background/shadow/icon/components/label) at a
// given content box — shared by the bar and popup builds.
void emitItem(DisplayList& list, ybar::model::Item& item, const ybar::model::Rect& contentBox,
              double scale, FontCache& fonts, GlyphAtlas& atlas, double clock = 0);

// Popup panel: popup.background plate + members at their layout boxes
// (panel-local, spec 3.9). Same paint order as the bar.
DisplayList buildPopupScene(const std::vector<ybar::model::Item*>& members,
                            const std::vector<ybar::model::Rect>& contentBoxes,
                            const ybar::model::PopupState& popup,
                            ybar::model::Size panelSize, double scale, FontCache& fonts,
                            GlyphAtlas& atlas);

} // namespace ybar::render
