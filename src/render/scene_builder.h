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
    // Pointer in LOGICAL points on this surface; negative = not over it.
    double pointerX = -1;
    double pointerY = -1;
    // The surface hosts a wallpaper-backdrop visual under each glass pill
    // (spec 7.6): emit DisplayList::backdrops and cut the bar background
    // under them. Off = the painted rim only, as before.
    bool backdrops = false;
};

// Clips a glyph quad to a device-px box and remaps its UVs proportionally —
// exact for axis-aligned quads, no scissor or stencil (spec 3.9). Returns
// false when the glyph lies fully outside; the caller drops the instance.
// Exposed for the headless UV-remap tests (spec 14).
bool clipGlyph(GlyphInstance& glyph, const Float2& clipMin, const Float2& clipMax);

DisplayList buildScene(const std::vector<std::unique_ptr<ybar::model::Item>>& items,
                       const std::unordered_map<int, ybar::model::Rect>& contentBoxes,
                       const ybar::model::BarSettings& settings, const SceneParams& params,
                       FontCache& fonts, GlyphAtlas& atlas);

// One item's full emission (background/shadow/icon/components/label) at a
// given content box — shared by the bar and popup builds.
void emitItem(DisplayList& list, ybar::model::Item& item, const ybar::model::Rect& contentBox,
              double scale, FontCache& fonts, GlyphAtlas& atlas, double clock = 0,
              bool backdrops = false);

// Popup panel: popup.background plate + members at their layout boxes
// (panel-local, spec 3.9). Same paint order as the bar. `opaquePanel` forces
// the panel plate to full alpha — the daemon sets it when Windows'
// Transparency effects are off, so a translucent theme panel reads flat like
// the rest of the shell (spec 7.6).
DisplayList buildPopupScene(const std::vector<ybar::model::Item*>& members,
                            const std::vector<ybar::model::Rect>& contentBoxes,
                            const ybar::model::PopupState& popup,
                            ybar::model::Size panelSize, double scale, FontCache& fonts,
                            GlyphAtlas& atlas, bool opaquePanel = false);

} // namespace ybar::render
