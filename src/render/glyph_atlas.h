// Glyph atlas (spec section 7.4): 2048x2048 R8 mask page (grayscale coverage,
// tinted in-shader) + 1024x1024 BGRA color page (emoji/images, later slice),
// shelf-packed, no eviction. One atlas per display scale.

#pragma once

#include <cstdint>
#include <memory>
#include <optional>

struct ID3D11ShaderResourceView; // global COM type, defined by d3d11.h

namespace ybar::render {

struct AtlasEntry {
    float uvOriginX = 0, uvOriginY = 0; // normalized
    float uvSizeX = 0, uvSizeY = 0;
    int widthPx = 0, heightPx = 0;
    int bearingX = 0, bearingY = 0; // pen -> cell top-left, y-down, device px
    bool color = false;
};

class GlyphAtlasImpl;

class GlyphAtlas {
public:
    // device/context are ID3D11Device*/ID3D11DeviceContext* (opaque here so
    // model-level code can include this header).
    static std::unique_ptr<GlyphAtlas> create(void* device, void* context, double scale);
    ~GlyphAtlas();

    double scale() const;

    // Rasterizes one glyph (grayscale AA) into the mask page. fontFace is
    // IDWriteFontFace*. nullopt when the page is full (stderr warning) or the
    // glyph has no ink.
    std::optional<AtlasEntry> maskGlyph(void* fontFace, float emSize, std::uint16_t glyphId);

    void* maskSrvRaw();  // ID3D11ShaderResourceView*
    void* colorSrvRaw();

    // Convenience for the renderer.
    ID3D11ShaderResourceView* maskSrv();
    ID3D11ShaderResourceView* colorSrv();

private:
    GlyphAtlas() = default;
    std::unique_ptr<GlyphAtlasImpl> impl_;
};

} // namespace ybar::render
