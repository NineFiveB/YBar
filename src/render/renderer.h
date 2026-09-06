// D3D11 renderer (spec section 7.1-7.3): one device shared across surfaces,
// runtime-compiled HLSL, three pipelines drawing a DisplayList into a
// composition swap chain through an sRGB render-target view.

#pragma once

#include <memory>
#include <string>

#include "render/instances.h"

namespace ybar::render {

class RendererImpl;

// One per-surface swap chain bundle, created by the Renderer.
class Surface {
public:
    virtual ~Surface() = default;
    virtual void resize(int widthPx, int heightPx) = 0;
    // IDXGISwapChain1*, handed to win/CompositionHost, which wraps it with
    // ICompositorInterop::CreateCompositionSurfaceForSwapChain.
    virtual void* compositionSurface() = 0;
};

class Renderer {
public:
    // Compiles shaders from `shaderPath` (HLSL source). Returns null on any
    // device/compile failure (error goes to stderr).
    static std::unique_ptr<Renderer> create(const std::string& shaderPath);
    ~Renderer();

    std::unique_ptr<Surface> createSurface(int widthPx, int heightPx);

    // Encodes and presents one frame. false = frame not produced; the caller
    // schedules a retry (spec 7.2).
    bool render(const DisplayList& list, Surface& surface, class GlyphAtlas* atlas);

    void* deviceRaw();  // ID3D11Device*
    void* contextRaw(); // ID3D11DeviceContext*

private:
    Renderer() = default;
    std::unique_ptr<RendererImpl> impl_;
};

} // namespace ybar::render
