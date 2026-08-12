// DirectWrite shaping + measurement (spec section 7.4). The load-bearing
// contract: width = (int)(inkBounds.width + 1.5) over tight ink bounds, and
// the ShapedLine metric set the scene builder aligns with.

#pragma once

#include <memory>
#include <string>
#include <vector>

#include "model/font_spec.h"

namespace ybar::render {

// One shaped glyph run: everything the atlas needs to rasterize and the
// scene builder needs to place. Positions are in layout space (DIPs,
// baseline-origin per glyph via advances/offsets).
struct ShapedRun {
    void* fontFace = nullptr; // IDWriteFontFace*, owned by the cache
    float fontEmSize = 0;
    float baselineOriginX = 0; // relative to the line's layout origin
    float baselineOriginY = 0;
    std::vector<std::uint16_t> glyphIds;
    std::vector<float> advances;
    std::vector<float> offsetsX;
    std::vector<float> offsetsY;
};

// One glyph's ink box in DIPs, positioned along the line's pen.
struct GlyphInk {
    double left = 0, right = 0;
    double bottom = 0, top = 0; // y-UP relative to the baseline (CoreText
                                // convention: descenders negative)
};

// Union of glyph ink boxes -> the metrics the layout contract is defined in.
struct InkBounds {
    double minX = 0, width = 0;
    double minY = 0, maxY = 0; // y-up, baseline-relative
    bool hasInk = false;
};
InkBounds unionInk(const std::vector<GlyphInk>& glyphs);

// The sketchybar parity formula (spec 3.9): tight ink, NOT advances, with
// this exact truncation. Every padding and alignment in a ported config
// depends on it.
inline double inkWidthToLayoutWidth(double inkWidth) {
    return static_cast<double>(static_cast<int>(inkWidth + 1.5));
}

struct ShapedLine {
    double width = 0;    // (int)(inkWidth + 1.5) — sketchybar parity formula
    double ascent = 0;   // from the primary font's metrics, DIPs
    double descent = 0;
    double inkWidth = 0;
    double inkMinX = 0;  // ink bounds relative to the layout origin
    double inkMinY = 0;  // y-UP relative to the baseline (negative below)
    double inkMaxY = 0;
    double baselineInLayout = 0; // layout-top -> baseline distance
    int glyphCount = 0;          // single-glyph icons center on INK (spec 3.9)
    std::vector<ShapedRun> runs;

    double measuredHeight() const; // ceil(ascent + descent)
};

class FontCacheImpl;

class FontCache {
public:
    static std::unique_ptr<FontCache> create();
    ~FontCache();

    // Shape + measure one line (cached by text+font). Never fails: an
    // unusable font falls back to the system default (Segoe UI Variable).
    const ShapedLine& shape(const std::string& text, const ybar::model::FontSpec& font);

    void clear(); // font-change invalidation

private:
    FontCache() = default;
    std::unique_ptr<FontCacheImpl> impl_;
};

} // namespace ybar::render
