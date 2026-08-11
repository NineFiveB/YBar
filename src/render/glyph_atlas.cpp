#include "render/glyph_atlas.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dwrite_2.h>
#include <wrl/client.h>
// clang-format on

#include <cstdio>
#include <unordered_map>
#include <vector>

using Microsoft::WRL::ComPtr;

namespace ybar::render {

namespace {

constexpr int kMaskSize = 2048;
constexpr int kColorSize = 1024;
constexpr int kPadding = 1;

// Trivial shelf packer (reference policy: first-fit shelves, height + h/8,
// no eviction).
struct ShelfPacker {
    int width, height;
    struct Shelf {
        int y, height, x;
    };
    std::vector<Shelf> shelves;
    int nextY = 0;

    ShelfPacker(int w, int h) : width(w), height(h) {}

    std::optional<std::pair<int, int>> pack(int w, int h) {
        for (auto& shelf : shelves) {
            if (h <= shelf.height && shelf.x + w <= width) {
                const auto pos = std::make_pair(shelf.x, shelf.y);
                shelf.x += w;
                return pos;
            }
        }
        const int shelfHeight = h + h / 8;
        if (nextY + shelfHeight > height) return std::nullopt;
        shelves.push_back({nextY, shelfHeight, w});
        const auto pos = std::make_pair(0, nextY);
        nextY += shelfHeight;
        return pos;
    }
};

struct GlyphKey {
    std::uintptr_t face;
    int quarterSize; // (emSize*4).rounded — quarter-point buckets
    std::uint16_t glyph;
    bool operator==(const GlyphKey&) const = default;
};

struct GlyphKeyHash {
    std::size_t operator()(const GlyphKey& k) const {
        return k.face ^ (static_cast<std::size_t>(k.quarterSize) << 20) ^
               (static_cast<std::size_t>(k.glyph) << 40);
    }
};

} // namespace

class GlyphAtlasImpl {
public:
    ID3D11Device* device = nullptr;
    ID3D11DeviceContext* context = nullptr;
    ComPtr<IDWriteFactory2> dwriteFactory;
    double scale = 1.0;

    ComPtr<ID3D11Texture2D> maskPage;
    ComPtr<ID3D11ShaderResourceView> maskView;
    ComPtr<ID3D11Texture2D> colorPage;
    ComPtr<ID3D11ShaderResourceView> colorView;

    ShelfPacker maskPacker{kMaskSize, kMaskSize};
    std::unordered_map<GlyphKey, std::optional<AtlasEntry>, GlyphKeyHash> entries;

    bool init() {
        if (FAILED(DWriteCreateFactory(
                DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory2),
                reinterpret_cast<IUnknown**>(dwriteFactory.GetAddressOf()))))
            return false;
        auto makePage = [&](int size, DXGI_FORMAT format, ComPtr<ID3D11Texture2D>& tex,
                            ComPtr<ID3D11ShaderResourceView>& view) {
            D3D11_TEXTURE2D_DESC desc{};
            desc.Width = static_cast<UINT>(size);
            desc.Height = static_cast<UINT>(size);
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = format;
            desc.SampleDesc.Count = 1;
            desc.Usage = D3D11_USAGE_DEFAULT;
            desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
            if (FAILED(device->CreateTexture2D(&desc, nullptr, &tex))) return false;
            return SUCCEEDED(device->CreateShaderResourceView(tex.Get(), nullptr, &view));
        };
        return makePage(kMaskSize, DXGI_FORMAT_R8_UNORM, maskPage, maskView) &&
               makePage(kColorSize, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB, colorPage, colorView);
    }
};

std::unique_ptr<GlyphAtlas> GlyphAtlas::create(void* device, void* context, double scale) {
    auto impl = std::make_unique<GlyphAtlasImpl>();
    impl->device = static_cast<ID3D11Device*>(device);
    impl->context = static_cast<ID3D11DeviceContext*>(context);
    impl->scale = scale;
    if (!impl->init()) return nullptr;
    std::unique_ptr<GlyphAtlas> atlas(new GlyphAtlas());
    atlas->impl_ = std::move(impl);
    return atlas;
}

GlyphAtlas::~GlyphAtlas() = default;

double GlyphAtlas::scale() const { return impl_->scale; }
void* GlyphAtlas::maskSrvRaw() { return impl_->maskView.Get(); }
void* GlyphAtlas::colorSrvRaw() { return impl_->colorView.Get(); }
ID3D11ShaderResourceView* GlyphAtlas::maskSrv() { return impl_->maskView.Get(); }
ID3D11ShaderResourceView* GlyphAtlas::colorSrv() { return impl_->colorView.Get(); }

std::optional<AtlasEntry> GlyphAtlas::maskGlyph(void* fontFaceRaw, float emSize,
                                                std::uint16_t glyphId) {
    auto* fontFace = static_cast<IDWriteFontFace*>(fontFaceRaw);
    const GlyphKey key{reinterpret_cast<std::uintptr_t>(fontFace),
                       static_cast<int>(emSize * impl_->scale * 4.0 + 0.5), glyphId};
    if (const auto it = impl_->entries.find(key); it != impl_->entries.end()) return it->second;

    // Rasterize at device-pixel size: bake the scale into the em size.
    const FLOAT scaledEm = static_cast<FLOAT>(emSize * impl_->scale);
    const UINT16 indices[1] = {glyphId};
    const FLOAT advances[1] = {0};
    const DWRITE_GLYPH_OFFSET offsets[1] = {{0, 0}};
    DWRITE_GLYPH_RUN run{};
    run.fontFace = fontFace;
    run.fontEmSize = scaledEm;
    run.glyphCount = 1;
    run.glyphIndices = indices;
    run.glyphAdvances = advances;
    run.glyphOffsets = offsets;

    // Grayscale AA via factory2 + ALIASED_1x1 (misnamed; spec 7.4).
    ComPtr<IDWriteGlyphRunAnalysis> analysis;
    if (FAILED(impl_->dwriteFactory->CreateGlyphRunAnalysis(
            &run, nullptr, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL,
            DWRITE_GRID_FIT_MODE_DEFAULT, DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, 0, 0,
            &analysis))) {
        impl_->entries.emplace(key, std::nullopt);
        return std::nullopt;
    }
    RECT bounds{};
    if (FAILED(analysis->GetAlphaTextureBounds(DWRITE_TEXTURE_ALIASED_1x1, &bounds)) ||
        bounds.right <= bounds.left || bounds.bottom <= bounds.top) {
        impl_->entries.emplace(key, std::nullopt); // no ink (e.g. space)
        return std::nullopt;
    }
    const int width = bounds.right - bounds.left;
    const int height = bounds.bottom - bounds.top;
    std::vector<BYTE> pixels(static_cast<std::size_t>(width) * height);
    if (FAILED(analysis->CreateAlphaTexture(DWRITE_TEXTURE_ALIASED_1x1, &bounds, pixels.data(),
                                            static_cast<UINT32>(pixels.size())))) {
        impl_->entries.emplace(key, std::nullopt);
        return std::nullopt;
    }

    const auto packed = impl_->maskPacker.pack(width + 2 * kPadding, height + 2 * kPadding);
    if (!packed) {
        std::fprintf(stderr, "[ybar] glyph atlas page full — glyph skipped\n");
        impl_->entries.emplace(key, std::nullopt);
        return std::nullopt;
    }
    const int x = packed->first + kPadding;
    const int y = packed->second + kPadding;

    D3D11_BOX box{static_cast<UINT>(x), static_cast<UINT>(y), 0, static_cast<UINT>(x + width),
                  static_cast<UINT>(y + height), 1};
    impl_->context->UpdateSubresource(impl_->maskPage.Get(), 0, &box, pixels.data(),
                                      static_cast<UINT>(width), 0);

    AtlasEntry entry;
    entry.uvOriginX = static_cast<float>(x) / kMaskSize;
    entry.uvOriginY = static_cast<float>(y) / kMaskSize;
    entry.uvSizeX = static_cast<float>(width) / kMaskSize;
    entry.uvSizeY = static_cast<float>(height) / kMaskSize;
    entry.widthPx = width;
    entry.heightPx = height;
    entry.bearingX = bounds.left; // pen -> ink top-left, y-down device px
    entry.bearingY = bounds.top;
    impl_->entries.emplace(key, entry);
    return entry;
}

} // namespace ybar::render
