#include "render/renderer.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <d3dcompiler.h>
#include <wrl/client.h>
// clang-format on

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <vector>

#include "render/glyph_atlas.h"

using Microsoft::WRL::ComPtr;

namespace ybar::render {

namespace {

ComPtr<ID3DBlob> compile(const std::string& source, const char* entry, const char* profile) {
    ComPtr<ID3DBlob> blob;
    ComPtr<ID3DBlob> errors;
    const HRESULT hr = D3DCompile(source.data(), source.size(), "ybar.hlsl", nullptr, nullptr,
                                  entry, profile, 0, 0, &blob, &errors);
    if (FAILED(hr)) {
        std::fprintf(stderr, "[ybar] shader compilation failed (%s): %s\n", entry,
                     errors ? static_cast<const char*>(errors->GetBufferPointer()) : "?");
        return nullptr;
    }
    return blob;
}

// Grow-only dynamic structured buffer with an SRV.
struct StructuredBuffer {
    ComPtr<ID3D11Buffer> buffer;
    ComPtr<ID3D11ShaderResourceView> srv;
    std::size_t capacityBytes = 0;

    bool upload(ID3D11Device* device, ID3D11DeviceContext* context, const void* data,
                std::size_t bytes, std::size_t stride) {
        if (bytes == 0) return true;
        if (bytes > capacityBytes) {
            capacityBytes = std::max<std::size_t>(bytes, std::max<std::size_t>(capacityBytes * 2, 16384));
            capacityBytes = ((capacityBytes + stride - 1) / stride) * stride; // stride multiple
            buffer.Reset();
            srv.Reset();
            D3D11_BUFFER_DESC desc{};
            desc.ByteWidth = static_cast<UINT>(capacityBytes);
            desc.Usage = D3D11_USAGE_DYNAMIC;
            desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
            desc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
            desc.MiscFlags = D3D11_RESOURCE_MISC_BUFFER_STRUCTURED;
            desc.StructureByteStride = static_cast<UINT>(stride);
            if (FAILED(device->CreateBuffer(&desc, nullptr, &buffer))) return false;
            D3D11_SHADER_RESOURCE_VIEW_DESC srvDesc{};
            srvDesc.Format = DXGI_FORMAT_UNKNOWN;
            srvDesc.ViewDimension = D3D11_SRV_DIMENSION_BUFFER;
            srvDesc.Buffer.NumElements = static_cast<UINT>(capacityBytes / stride);
            if (FAILED(device->CreateShaderResourceView(buffer.Get(), &srvDesc, &srv)))
                return false;
        }
        D3D11_MAPPED_SUBRESOURCE mapped;
        if (FAILED(context->Map(buffer.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)))
            return false;
        std::memcpy(mapped.pData, data, bytes);
        context->Unmap(buffer.Get(), 0);
        return true;
    }
};

} // namespace

class RendererImpl {
public:
    ComPtr<ID3D11Device> device;
    ComPtr<ID3D11DeviceContext> context;
    ComPtr<IDXGIFactory2> dxgiFactory;

    ComPtr<ID3D11VertexShader> quadVS, shapeVS, glyphVS;
    ComPtr<ID3D11PixelShader> quadPS, shapePS, glyphPS;
    ComPtr<ID3D11BlendState> blend;             // premultiplied ONE / INV_SRC_ALPHA
    ComPtr<ID3D11RasterizerState> rasterizer;   // CULL_NONE (spec 7.3)
    ComPtr<ID3D11SamplerState> sampler;         // linear, clamp
    ComPtr<ID3D11Buffer> uniforms;              // cbuffer b1

    StructuredBuffer quads, glyphs, shapes, holes;

    bool init(const std::string& shaderPath);
};

namespace {

class SurfaceImpl final : public Surface {
public:
    ComPtr<IDXGISwapChain1> swapChain;
    ComPtr<ID3D11RenderTargetView> rtv; // *_SRGB view over the UNORM backbuffer
    ID3D11Device* device = nullptr;
    int width = 0;
    int height = 0;

    bool createRtv() {
        rtv.Reset();
        ComPtr<ID3D11Texture2D> backBuffer;
        if (FAILED(swapChain->GetBuffer(0, IID_PPV_ARGS(&backBuffer)))) return false;
        D3D11_RENDER_TARGET_VIEW_DESC desc{};
        desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM_SRGB; // documented RTV exception
        desc.ViewDimension = D3D11_RTV_DIMENSION_TEXTURE2D;
        return SUCCEEDED(device->CreateRenderTargetView(backBuffer.Get(), &desc, &rtv));
    }

    void resize(int widthPx, int heightPx) override {
        if (widthPx == width && heightPx == height) return;

        // ResizeBuffers refuses while ANY reference to the back buffer is
        // outstanding, and rtv.Reset() alone is not enough: D3D11 destroys
        // objects LAZILY, so the view lives on past its last Release and keeps
        // the buffer alive. That deferred destruction is what returned
        // DXGI_ERROR_INVALID_CALL — unchecked — leaving the swap chain at its
        // old size while createRtv() below re-viewed the stale back buffer.
        // Flush() is the call that fixes it: it retires the pending destroy.
        //
        // The unbind is belt-and-braces, not the cure. This is a flip-model
        // swap chain (FLIP_SEQUENTIAL), where Present unbinds the back buffer
        // from the output merger — which is exactly why render() re-binds it
        // every frame — and every path that binds reaches Present, so the OM
        // is already empty here. It stays because it costs nothing and is the
        // documented precondition if that ever stops holding.
        rtv.Reset();
        ComPtr<ID3D11DeviceContext> context;
        device->GetImmediateContext(&context);
        if (context) {
            context->OMSetRenderTargets(0, nullptr, nullptr);
            context->Flush(); // retire the deferred destroy of the old view
        }

        const HRESULT hr = swapChain->ResizeBuffers(
            0, static_cast<UINT>(widthPx), static_cast<UINT>(heightPx), DXGI_FORMAT_UNKNOWN, 0);
        if (FAILED(hr)) {
            // Commit the new size only on success, so the viewport render()
            // derives from width/height keeps matching the real back buffer.
            // This does NOT buy a retry: both callers record the size they
            // asked for whether or not it took (bar_surface.cpp
            // lastAppliedFrame, popup_surface.cpp widthPx/heightPx), so a
            // failed resize stands until the next genuine size change.
            // Rebuild a view regardless — the surface then keeps drawing at
            // its old size instead of going black.
            std::fprintf(stderr, "[ybar] swap chain resize to %dx%d failed (0x%08lx)\n", widthPx,
                         heightPx, static_cast<unsigned long>(hr));
            createRtv();
            return;
        }
        width = widthPx;
        height = heightPx;
        createRtv();
    }

    void* compositionSurface() override { return swapChain.Get(); }
};

} // namespace

bool RendererImpl::init(const std::string& shaderPath) {
    const UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags, nullptr, 0,
                                 D3D11_SDK_VERSION, &device, nullptr, &context))) {
        std::fprintf(stderr, "[ybar] D3D11 device creation failed\n");
        return false;
    }
    ComPtr<IDXGIDevice> dxgiDevice;
    device.As(&dxgiDevice);
    ComPtr<IDXGIAdapter> adapter;
    dxgiDevice->GetAdapter(&adapter);
    if (FAILED(adapter->GetParent(IID_PPV_ARGS(&dxgiFactory)))) return false;

    std::ifstream file(shaderPath, std::ios::binary);
    if (!file) {
        std::fprintf(stderr, "[ybar] shader source not found: %s\n", shaderPath.c_str());
        return false;
    }
    std::ostringstream stream;
    stream << file.rdbuf();
    const std::string source = stream.str();

    const auto quadVsBlob = compile(source, "quad_vertex", "vs_5_0");
    const auto quadPsBlob = compile(source, "quad_fragment", "ps_5_0");
    const auto shapeVsBlob = compile(source, "shape_vertex", "vs_5_0");
    const auto shapePsBlob = compile(source, "shape_fragment", "ps_5_0");
    const auto glyphVsBlob = compile(source, "glyph_vertex", "vs_5_0");
    const auto glyphPsBlob = compile(source, "glyph_fragment", "ps_5_0");
    if (!quadVsBlob || !quadPsBlob || !shapeVsBlob || !shapePsBlob || !glyphVsBlob ||
        !glyphPsBlob)
        return false;

    auto makeVS = [&](const ComPtr<ID3DBlob>& blob, ComPtr<ID3D11VertexShader>& out) {
        return SUCCEEDED(device->CreateVertexShader(blob->GetBufferPointer(),
                                                    blob->GetBufferSize(), nullptr, &out));
    };
    auto makePS = [&](const ComPtr<ID3DBlob>& blob, ComPtr<ID3D11PixelShader>& out) {
        return SUCCEEDED(device->CreatePixelShader(blob->GetBufferPointer(),
                                                   blob->GetBufferSize(), nullptr, &out));
    };
    if (!makeVS(quadVsBlob, quadVS) || !makePS(quadPsBlob, quadPS) ||
        !makeVS(shapeVsBlob, shapeVS) || !makePS(shapePsBlob, shapePS) ||
        !makeVS(glyphVsBlob, glyphVS) || !makePS(glyphPsBlob, glyphPS))
        return false;

    D3D11_BLEND_DESC blendDesc{};
    blendDesc.RenderTarget[0].BlendEnable = TRUE;
    blendDesc.RenderTarget[0].SrcBlend = D3D11_BLEND_ONE;
    blendDesc.RenderTarget[0].DestBlend = D3D11_BLEND_INV_SRC_ALPHA;
    blendDesc.RenderTarget[0].BlendOp = D3D11_BLEND_OP_ADD;
    blendDesc.RenderTarget[0].SrcBlendAlpha = D3D11_BLEND_ONE;
    blendDesc.RenderTarget[0].DestBlendAlpha = D3D11_BLEND_INV_SRC_ALPHA;
    blendDesc.RenderTarget[0].BlendOpAlpha = D3D11_BLEND_OP_ADD;
    blendDesc.RenderTarget[0].RenderTargetWriteMask = D3D11_COLOR_WRITE_ENABLE_ALL;
    if (FAILED(device->CreateBlendState(&blendDesc, &blend))) return false;

    D3D11_RASTERIZER_DESC rasterDesc{};
    rasterDesc.FillMode = D3D11_FILL_SOLID;
    rasterDesc.CullMode = D3D11_CULL_NONE; // strip winding is mixed (spec 7.3)
    if (FAILED(device->CreateRasterizerState(&rasterDesc, &rasterizer))) return false;

    D3D11_SAMPLER_DESC samplerDesc{};
    samplerDesc.Filter = D3D11_FILTER_MIN_MAG_MIP_LINEAR;
    samplerDesc.AddressU = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.AddressV = D3D11_TEXTURE_ADDRESS_CLAMP;
    samplerDesc.AddressW = D3D11_TEXTURE_ADDRESS_CLAMP;
    if (FAILED(device->CreateSamplerState(&samplerDesc, &sampler))) return false;

    D3D11_BUFFER_DESC uniformDesc{};
    uniformDesc.ByteWidth = sizeof(Uniforms);
    uniformDesc.Usage = D3D11_USAGE_DYNAMIC;
    uniformDesc.BindFlags = D3D11_BIND_CONSTANT_BUFFER;
    uniformDesc.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    return SUCCEEDED(device->CreateBuffer(&uniformDesc, nullptr, &uniforms));
}

void* Renderer::deviceRaw() { return impl_->device.Get(); }
void* Renderer::contextRaw() { return impl_->context.Get(); }

std::unique_ptr<Renderer> Renderer::create(const std::string& shaderPath) {
    auto impl = std::make_unique<RendererImpl>();
    if (!impl->init(shaderPath)) return nullptr;
    std::unique_ptr<Renderer> renderer(new Renderer());
    renderer->impl_ = std::move(impl);
    return renderer;
}

Renderer::~Renderer() = default;

std::unique_ptr<Surface> Renderer::createSurface(int widthPx, int heightPx) {
    auto surface = std::make_unique<SurfaceImpl>();
    surface->device = impl_->device.Get();
    surface->width = widthPx;
    surface->height = heightPx;

    DXGI_SWAP_CHAIN_DESC1 desc{};
    desc.Width = static_cast<UINT>(widthPx);
    desc.Height = static_cast<UINT>(heightPx);
    desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM; // flip model rejects *_SRGB (spec 7.1)
    desc.SampleDesc.Count = 1;
    desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    desc.BufferCount = 3;
    desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
    desc.Scaling = DXGI_SCALING_STRETCH;
    desc.AlphaMode = DXGI_ALPHA_MODE_PREMULTIPLIED;
    if (FAILED(impl_->dxgiFactory->CreateSwapChainForComposition(impl_->device.Get(), &desc,
                                                                 nullptr, &surface->swapChain)))
        return nullptr;
    if (!surface->createRtv()) return nullptr;
    return surface;
}

bool Renderer::render(const DisplayList& list, Surface& surfaceBase, GlyphAtlas* atlas) {
    auto& surface = static_cast<SurfaceImpl&>(surfaceBase);
    auto* context = impl_->context.Get();
    auto* device = impl_->device.Get();
    if (!surface.rtv) return false;

    if (std::getenv("YBAR_DEBUG")) {
        DXGI_SWAP_CHAIN_DESC1 desc{};
        surface.swapChain->GetDesc1(&desc);
        std::fprintf(stderr,
                     "[ybar:render] surface=%dx%d buffer=%ux%u viewport=%.0fx%.0f quads=%zu "
                     "glyphs=%zu",
                     surface.width, surface.height, desc.Width, desc.Height,
                     list.viewportSize.x, list.viewportSize.y, list.quads.size(),
                     list.glyphs.size());
        if (!list.glyphs.empty()) {
            std::fprintf(stderr, " firstGlyph=(%.0f,%.0f) lastGlyph=(%.0f,%.0f)",
                         list.glyphs.front().origin.x, list.glyphs.front().origin.y,
                         list.glyphs.back().origin.x, list.glyphs.back().origin.y);
        }
        std::fprintf(stderr, "\n");
        std::fflush(stderr);
    }

    // Uniforms (b1, both stages).
    Uniforms uniforms;
    uniforms.viewportSize = list.viewportSize;
    uniforms.holeCount = static_cast<std::uint32_t>(list.holes.size());
    uniforms.pointer = list.pointer;
    D3D11_MAPPED_SUBRESOURCE mapped;
    if (FAILED(context->Map(impl_->uniforms.Get(), 0, D3D11_MAP_WRITE_DISCARD, 0, &mapped)))
        return false;
    std::memcpy(mapped.pData, &uniforms, sizeof(uniforms));
    context->Unmap(impl_->uniforms.Get(), 0);

    // Instance uploads.
    static const Hole kDummyHole{};
    const void* holeData = list.holes.empty() ? &kDummyHole : list.holes.data();
    const std::size_t holeBytes = std::max<std::size_t>(list.holes.size(), 1) * sizeof(Hole);
    if (!impl_->quads.upload(device, context, list.quads.data(),
                             list.quads.size() * sizeof(QuadInstance), sizeof(QuadInstance)) ||
        !impl_->glyphs.upload(device, context, list.glyphs.data(),
                              list.glyphs.size() * sizeof(GlyphInstance),
                              sizeof(GlyphInstance)) ||
        !impl_->shapes.upload(device, context, list.shapeVertices.data(),
                              list.shapeVertices.size() * sizeof(ShapeVertex),
                              sizeof(ShapeVertex)) ||
        !impl_->holes.upload(device, context, holeData, holeBytes, sizeof(Hole)))
        return false;

    const float clear[4] = {0, 0, 0, 0};
    context->ClearRenderTargetView(surface.rtv.Get(), clear);
    ID3D11RenderTargetView* rtv = surface.rtv.Get();
    context->OMSetRenderTargets(1, &rtv, nullptr);
    context->OMSetBlendState(impl_->blend.Get(), nullptr, 0xffffffff);
    context->RSSetState(impl_->rasterizer.Get());
    D3D11_VIEWPORT viewport{0, 0, static_cast<float>(surface.width),
                            static_cast<float>(surface.height), 0, 1};
    context->RSSetViewports(1, &viewport);
    ID3D11Buffer* cb = impl_->uniforms.Get();
    context->VSSetConstantBuffers(1, 1, &cb);
    context->PSSetConstantBuffers(1, 1, &cb);
    context->IASetInputLayout(nullptr); // vertex pulling
    context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

    // 1) quads
    if (!list.quads.empty()) {
        context->VSSetShader(impl_->quadVS.Get(), nullptr, 0);
        context->PSSetShader(impl_->quadPS.Get(), nullptr, 0);
        ID3D11ShaderResourceView* vsSrv = impl_->quads.srv.Get();
        context->VSSetShaderResources(0, 1, &vsSrv);
        ID3D11ShaderResourceView* holeSrv = impl_->holes.srv.Get();
        context->PSSetShaderResources(2, 1, &holeSrv);
        context->DrawInstanced(4, static_cast<UINT>(list.quads.size()), 0, 0);
    }
    // 2) shape triangles
    if (!list.shapeVertices.empty()) {
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(impl_->shapeVS.Get(), nullptr, 0);
        context->PSSetShader(impl_->shapePS.Get(), nullptr, 0);
        ID3D11ShaderResourceView* vsSrv = impl_->shapes.srv.Get();
        context->VSSetShaderResources(0, 1, &vsSrv);
        context->Draw(static_cast<UINT>(list.shapeVertices.size()), 0);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
    }
    // 3) glyphs over everything
    if (!list.glyphs.empty() && atlas) {
        context->VSSetShader(impl_->glyphVS.Get(), nullptr, 0);
        context->PSSetShader(impl_->glyphPS.Get(), nullptr, 0);
        ID3D11ShaderResourceView* vsSrv = impl_->glyphs.srv.Get();
        context->VSSetShaderResources(0, 1, &vsSrv);
        ID3D11ShaderResourceView* pages[2] = {atlas->maskSrv(), atlas->colorSrv()};
        context->PSSetShaderResources(0, 2, pages);
        ID3D11SamplerState* samp = impl_->sampler.Get();
        context->PSSetSamplers(0, 1, &samp);
        context->DrawInstanced(4, static_cast<UINT>(list.glyphs.size()), 0, 0);
    }

    ID3D11ShaderResourceView* nullSrvs[3] = {};
    context->VSSetShaderResources(0, 1, nullSrvs);
    context->PSSetShaderResources(0, 3, nullSrvs);

    return SUCCEEDED(surface.swapChain->Present(1, 0));
}

} // namespace ybar::render
