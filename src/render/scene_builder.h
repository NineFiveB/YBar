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
};

DisplayList buildScene(const std::vector<std::unique_ptr<ybar::model::Item>>& items,
                       const std::unordered_map<int, ybar::model::Rect>& contentBoxes,
                       const ybar::model::BarSettings& settings, const SceneParams& params,
                       FontCache& fonts, GlyphAtlas& atlas);

} // namespace ybar::render
