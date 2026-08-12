#include "render/font_cache.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dwrite_2.h>
#include <wrl/client.h>
// clang-format on

#include <cmath>
#include <cstdio>
#include <unordered_map>

#include "render/icon_map.h"

using Microsoft::WRL::ComPtr;

namespace ybar::render {

double ShapedLine::measuredHeight() const { return std::ceil(ascent + descent); }

InkBounds unionInk(const std::vector<GlyphInk>& glyphs) {
    InkBounds bounds;
    double maxX = 0;
    for (const auto& glyph : glyphs) {
        // Blank glyphs (space) carry no ink and must not widen the box.
        if (glyph.right <= glyph.left || glyph.top <= glyph.bottom) continue;
        if (!bounds.hasInk) {
            bounds.hasInk = true;
            bounds.minX = glyph.left;
            maxX = glyph.right;
            bounds.minY = glyph.bottom;
            bounds.maxY = glyph.top;
            continue;
        }
        bounds.minX = std::min(bounds.minX, glyph.left);
        maxX = std::max(maxX, glyph.right);
        bounds.minY = std::min(bounds.minY, glyph.bottom);
        bounds.maxY = std::max(bounds.maxY, glyph.top);
    }
    bounds.width = bounds.hasInk ? maxX - bounds.minX : 0;
    return bounds;
}

namespace {

// Collects glyph runs from IDWriteTextLayout::Draw — the pragmatic
// AtlasEngine-lite shaping path (fallback and shaping handled by DirectWrite).
class RunCollector final : public IDWriteTextRenderer {
public:
    std::vector<ShapedRun>* runs = nullptr;
    std::vector<ComPtr<IDWriteFontFace>>* keepAlive = nullptr;

    // IUnknown — stack-allocated, no real refcounting needed.
    ULONG STDMETHODCALLTYPE AddRef() override { return 2; }
    ULONG STDMETHODCALLTYPE Release() override { return 1; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void** object) override {
        if (riid == __uuidof(IDWriteTextRenderer) || riid == __uuidof(IDWritePixelSnapping) ||
            riid == __uuidof(IUnknown)) {
            *object = this;
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }

    // IDWritePixelSnapping
    HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void*, BOOL* disabled) override {
        *disabled = TRUE; // we snap ourselves at device-pixel granularity
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetCurrentTransform(void*, DWRITE_MATRIX* transform) override {
        *transform = {1, 0, 0, 1, 0, 0};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void*, FLOAT* pixelsPerDip) override {
        *pixelsPerDip = 1.0f;
        return S_OK;
    }

    // IDWriteTextRenderer
    HRESULT STDMETHODCALLTYPE DrawGlyphRun(void*, FLOAT baselineOriginX, FLOAT baselineOriginY,
                                           DWRITE_MEASURING_MODE,
                                           DWRITE_GLYPH_RUN const* glyphRun,
                                           DWRITE_GLYPH_RUN_DESCRIPTION const*,
                                           IUnknown*) override {
        ShapedRun run;
        run.fontFace = glyphRun->fontFace;
        run.fontEmSize = glyphRun->fontEmSize;
        run.baselineOriginX = baselineOriginX;
        run.baselineOriginY = baselineOriginY;
        for (UINT32 i = 0; i < glyphRun->glyphCount; ++i) {
            run.glyphIds.push_back(glyphRun->glyphIndices[i]);
            run.advances.push_back(glyphRun->glyphAdvances ? glyphRun->glyphAdvances[i] : 0);
            run.offsetsX.push_back(glyphRun->glyphOffsets ? glyphRun->glyphOffsets[i].advanceOffset
                                                          : 0);
            run.offsetsY.push_back(
                glyphRun->glyphOffsets ? glyphRun->glyphOffsets[i].ascenderOffset : 0);
        }
        keepAlive->emplace_back(glyphRun->fontFace); // AddRef via ComPtr
        runs->push_back(std::move(run));
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawUnderline(void*, FLOAT, FLOAT, DWRITE_UNDERLINE const*,
                                            IUnknown*) override {
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawStrikethrough(void*, FLOAT, FLOAT,
                                                DWRITE_STRIKETHROUGH const*, IUnknown*) override {
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE DrawInlineObject(void*, FLOAT, FLOAT, IDWriteInlineObject*, BOOL,
                                               BOOL, IUnknown*) override {
        return S_OK;
    }
};

std::wstring widen(const std::string& utf8) {
    if (utf8.empty()) return {};
    const int size = MultiByteToWideChar(CP_UTF8, 0, utf8.data(),
                                         static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring wide(static_cast<std::size_t>(size), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), wide.data(),
                        size);
    return wide;
}

DWRITE_FONT_WEIGHT weightFor(const std::string& style) {
    std::string s = style;
    for (auto& c : s)
        if (c >= 'A' && c <= 'Z') c += 32;
    if (s == "ultralight") return DWRITE_FONT_WEIGHT_THIN;
    if (s == "thin") return DWRITE_FONT_WEIGHT_EXTRA_LIGHT;
    if (s == "light") return DWRITE_FONT_WEIGHT_LIGHT;
    if (s == "medium") return DWRITE_FONT_WEIGHT_MEDIUM;
    if (s.find("semibold") != std::string::npos) return DWRITE_FONT_WEIGHT_SEMI_BOLD;
    if (s.find("bold") != std::string::npos) return DWRITE_FONT_WEIGHT_BOLD;
    if (s == "heavy") return DWRITE_FONT_WEIGHT_EXTRA_BOLD;
    if (s == "black") return DWRITE_FONT_WEIGHT_BLACK;
    return DWRITE_FONT_WEIGHT_REGULAR;
}

DWRITE_FONT_STYLE styleFor(const std::string& style) {
    std::string s = style;
    for (auto& c : s)
        if (c >= 'A' && c <= 'Z') c += 32;
    return s.find("italic") != std::string::npos ? DWRITE_FONT_STYLE_ITALIC
                                                 : DWRITE_FONT_STYLE_NORMAL;
}

} // namespace

class FontCacheImpl {
public:
    ComPtr<IDWriteFactory> factory;
    std::unordered_map<std::string, ShapedLine> lines;
    std::vector<ComPtr<IDWriteFontFace>> facesKeepAlive;

    bool init() {
        if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                       reinterpret_cast<IUnknown**>(factory.GetAddressOf()))))
            return false;
        pickIconFont();
        return true;
    }

    // Segoe Fluent Icons (Win11) -> Segoe MDL2 Assets (Win10) -> bundled
    // fluentui fallback (spec 7.5).
    void pickIconFont() {
        ComPtr<IDWriteFontCollection> system;
        if (FAILED(factory->GetSystemFontCollection(&system))) return;
        for (const wchar_t* family :
             {L"Segoe Fluent Icons", L"Segoe MDL2 Assets", L"FluentSystemIcons-Resizable"}) {
            UINT32 index = 0;
            BOOL exists = FALSE;
            if (SUCCEEDED(system->FindFamilyName(family, &index, &exists)) && exists) {
                setIconFontFamily(family);
                return;
            }
        }
        std::fprintf(stderr, "[ybar] no icon font found — sf: glyphs will not render\n");
    }
};

std::unique_ptr<FontCache> FontCache::create() {
    auto impl = std::make_unique<FontCacheImpl>();
    if (!impl->init()) {
        std::fprintf(stderr, "[ybar] DirectWrite factory creation failed\n");
        return nullptr;
    }
    std::unique_ptr<FontCache> cache(new FontCache());
    cache->impl_ = std::move(impl);
    return cache;
}

FontCache::~FontCache() = default;

void FontCache::clear() {
    // Wholesale eviction (reference behavior on font-change/reload).
    impl_->lines.clear();
    impl_->facesKeepAlive.clear();
}

const ShapedLine& FontCache::shape(const std::string& text, const ybar::model::FontSpec& font) {
    if (impl_->lines.size() > 1024) clear(); // wholesale eviction cap

    const std::string key =
        text + "\x1f" + font.family + "\x1f" + font.style + "\x1f" + std::to_string(font.size);
    if (const auto it = impl_->lines.find(key); it != impl_->lines.end()) return it->second;

    ShapedLine line;
    // "sf:<name>" shapes the mapped icon glyph in the icon font, ignoring the
    // part's own family (spec 7.5) — the grammar is the contract, the artwork
    // is platform-specific.
    const auto symbol = symbolName(text);
    const std::string shapedText =
        symbol.empty() ? text : resolveSymbol(symbol).text;
    const std::wstring family = !symbol.empty() ? iconFontFamily()
                                : font.family.empty() ? L"Segoe UI Variable"
                                                      : widen(font.family);
    const auto emSize = static_cast<FLOAT>(font.size);

    ComPtr<IDWriteTextFormat> format;
    if (SUCCEEDED(impl_->factory->CreateTextFormat(
            family.c_str(), nullptr, weightFor(font.style), styleFor(font.style),
            DWRITE_FONT_STRETCH_NORMAL, emSize, L"", &format))) {
        const std::wstring wide = widen(shapedText);
        ComPtr<IDWriteTextLayout> layout;
        if (SUCCEEDED(impl_->factory->CreateTextLayout(wide.c_str(),
                                                       static_cast<UINT32>(wide.size()),
                                                       format.Get(), 1e6f, 1e6f, &layout))) {
            DWRITE_TEXT_METRICS metrics{};
            layout->GetMetrics(&metrics);
            DWRITE_LINE_METRICS lineMetrics{};
            UINT32 lineCount = 1;
            layout->GetLineMetrics(&lineMetrics, 1, &lineCount);

            line.baselineInLayout = lineMetrics.baseline;
            // Primary-font vertical metrics (em box).
            line.ascent = lineMetrics.baseline;
            line.descent = lineMetrics.height - lineMetrics.baseline;

            RunCollector collector;
            collector.runs = &line.runs;
            collector.keepAlive = &impl_->facesKeepAlive;
            layout->Draw(nullptr, &collector, 0, 0);

            // Tight ink bounds (spec 7.4): the reference measures glyph-PATH
            // bounds, so accumulate per-glyph design metrics along the pen.
            // DirectWrite has no single-call equivalent of
            // CTLineGetBoundsWithOptions(.useGlyphPathBounds).
            std::vector<GlyphInk> inks;
            for (const auto& run : line.runs) {
                auto* face = static_cast<IDWriteFontFace*>(run.fontFace);
                if (!face || run.glyphIds.empty()) continue;
                DWRITE_FONT_METRICS faceMetrics{};
                face->GetMetrics(&faceMetrics);
                if (faceMetrics.designUnitsPerEm == 0) continue;
                const double unit =
                    run.fontEmSize / static_cast<double>(faceMetrics.designUnitsPerEm);

                std::vector<DWRITE_GLYPH_METRICS> glyphMetrics(run.glyphIds.size());
                if (FAILED(face->GetDesignGlyphMetrics(run.glyphIds.data(),
                                                       static_cast<UINT32>(run.glyphIds.size()),
                                                       glyphMetrics.data(), FALSE)))
                    continue;

                double pen = run.baselineOriginX;
                for (std::size_t i = 0; i < run.glyphIds.size(); ++i) {
                    const auto& m = glyphMetrics[i];
                    const double x = pen + run.offsetsX[i];
                    const double y = run.offsetsY[i]; // y-up offset
                    GlyphInk ink;
                    ink.left = x + m.leftSideBearing * unit;
                    ink.right =
                        x + (static_cast<double>(m.advanceWidth) - m.rightSideBearing) * unit;
                    ink.top = y + (static_cast<double>(m.verticalOriginY) - m.topSideBearing) * unit;
                    ink.bottom = y + (static_cast<double>(m.verticalOriginY) -
                                      static_cast<double>(m.advanceHeight) +
                                      m.bottomSideBearing) * unit;
                    inks.push_back(ink);
                    pen += run.advances[i];
                }
                line.glyphCount += static_cast<int>(run.glyphIds.size());
            }

            const auto bounds = unionInk(inks);
            line.inkMinX = bounds.minX;
            line.inkWidth = bounds.width;
            line.inkMinY = bounds.minY;
            line.inkMaxY = bounds.maxY;
            line.width = inkWidthToLayoutWidth(line.inkWidth);
            if (!bounds.hasInk) { // whitespace-only: fall back to advances
                line.inkWidth = metrics.widthIncludingTrailingWhitespace;
                line.width = inkWidthToLayoutWidth(line.inkWidth);
                line.inkMinY = -line.ascent;
                line.inkMaxY = line.descent;
            }
        }
    }

    return impl_->lines.emplace(key, std::move(line)).first->second;
}

} // namespace ybar::render
