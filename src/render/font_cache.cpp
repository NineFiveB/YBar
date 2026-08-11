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

using Microsoft::WRL::ComPtr;

namespace ybar::render {

double ShapedLine::measuredHeight() const { return std::ceil(ascent + descent); }

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
        return SUCCEEDED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED,
                                             __uuidof(IDWriteFactory),
                                             reinterpret_cast<IUnknown**>(&factory)));
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
    const std::wstring family = font.family.empty() ? L"Segoe UI Variable" : widen(font.family);
    const auto emSize = static_cast<FLOAT>(font.size);

    ComPtr<IDWriteTextFormat> format;
    if (SUCCEEDED(impl_->factory->CreateTextFormat(
            family.c_str(), nullptr, weightFor(font.style), styleFor(font.style),
            DWRITE_FONT_STRETCH_NORMAL, emSize, L"", &format))) {
        const std::wstring wide = widen(text);
        ComPtr<IDWriteTextLayout> layout;
        if (SUCCEEDED(impl_->factory->CreateTextLayout(wide.c_str(),
                                                       static_cast<UINT32>(wide.size()),
                                                       format.Get(), 1e6f, 1e6f, &layout))) {
            DWRITE_TEXT_METRICS metrics{};
            layout->GetMetrics(&metrics);
            DWRITE_LINE_METRICS lineMetrics{};
            UINT32 lineCount = 1;
            layout->GetLineMetrics(&lineMetrics, 1, &lineCount);

            // Pragmatic v1 ink model: advance-based width. The per-glyph
            // tight-ink accumulation (and its golden-value parity suite,
            // spec 14) replaces this in the metric-parity pass; the +1.5
            // truncation contract is already applied here.
            line.inkMinX = 0;
            line.inkWidth = metrics.widthIncludingTrailingWhitespace;
            line.width = static_cast<double>(static_cast<int>(line.inkWidth + 1.5));
            line.baselineInLayout = lineMetrics.baseline;

            // Primary-font vertical metrics.
            line.ascent = lineMetrics.baseline;
            line.descent = lineMetrics.height - lineMetrics.baseline;
            line.inkMinY = -line.ascent;
            line.inkMaxY = line.descent;

            RunCollector collector;
            collector.runs = &line.runs;
            collector.keepAlive = &impl_->facesKeepAlive;
            layout->Draw(nullptr, &collector, 0, 0);
        }
    }

    return impl_->lines.emplace(key, std::move(line)).first->second;
}

} // namespace ybar::render
