#include "win/composition_host.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dxgi1_3.h>
#include <dispatcherqueue.h>
#include <windows.ui.composition.interop.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Numerics.h>
#include <winrt/Windows.UI.Composition.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
// clang-format on

#include <cstdint>
#include <cstdio>
#include <cstdlib>

// Why Windows.UI.Composition and not DirectComposition, which both window
// types used before: a per-pill material needs a brush that samples what is
// BEHIND the window, and dcomp.h has no such concept. Windows.UI.Composition
// has two candidates, and only one of them is real for an unpackaged app:
//
//   * CreateHostBackdropBrush is inert outside a packaged/UWP context:
//     measured on this window shape, it paints black.
//   * TryCreateBlurredWallpaperBackdropBrush works: on exactly this window
//     (topmost, never activated, WS_EX_NOREDIRECTIONBITMAP), and regardless
//     of the Transparency-effects setting, which the DWM backdrops honour by
//     dropping to a solid fallback. It is the blurred desktop wallpaper in
//     screen space, which is what Mica is made of. The pill's own translucent
//     fill, painted over it in the swap chain, is the tint.
//
// Tree, bottom to top:
//   root (ContainerVisual, fills the window; its Opacity is the popup fade)
//     backdrops (ContainerVisual): one SpriteVisual per entry, wallpaper
//                                  brush, rounded-rectangle geometric clip
//     content (SpriteVisual): the swap chain as a surface brush
//
// A bar sends one entry per glass pill, and its background quad has a hole
// cut under each (scene_builder, the background.clip mechanism), so the
// material shows through and only the pill's fill composites over it. A
// popup sends one entry for the whole panel with NO hole -- nothing is
// painted beneath a panel -- plus one per glass row, which does cut a hole.
//
// Coordinates: a DesktopWindowTarget composes in the window's physical-pixel
// space for a PerMonitorV2 process, the same as the DirectComposition target
// it replaced, so the display list's device-px rects are used verbatim.

namespace wuc = winrt::Windows::UI::Composition;
namespace abi_comp = ABI::Windows::UI::Composition;

namespace ybar::win {

namespace {

// Per-thread compositor state, created on first use and deliberately never
// destroyed: the daemon's UI thread lives as long as the process, and a
// WinRT object in static storage would be released after COM was torn down
// at exit, which is a crash on the way out for no benefit.
struct Shared {
    ABI::Windows::System::IDispatcherQueueController* dispatcher = nullptr;
    wuc::Compositor compositor{nullptr};
    wuc::CompositionBrush wallpaper{nullptr};
    bool ok = false;
};

// A failure here is NOT latched: the daemon rebuilds its surfaces on a
// backoff when one is missing, and that recovery only means something if
// each attempt is a fresh try at the compositor too. The dispatcher queue,
// once created, is kept (a thread gets one); the compositor and brush are
// retried until they exist. Failures are logged once, not once per retry.
Shared* shared() {
    static Shared* instance = new Shared();
    static bool warned = false;
    Shared* s = instance;
    if (s->ok) return s;
    if (!s->dispatcher) {
        // A Compositor needs a DispatcherQueue on its thread. The UI thread
        // is already an STA (CoInitializeEx in the daemon), which STA here
        // simply re-affirms; NONE is the fallback if a build ever objects.
        DispatcherQueueOptions options{sizeof(DispatcherQueueOptions), DQTYPE_THREAD_CURRENT,
                                       DQTAT_COM_STA};
        HRESULT hr = CreateDispatcherQueueController(options, &s->dispatcher);
        if (FAILED(hr)) {
            options.apartmentType = DQTAT_COM_NONE;
            hr = CreateDispatcherQueueController(options, &s->dispatcher);
        }
        if (FAILED(hr)) {
            s->dispatcher = nullptr;
            if (!warned) {
                std::fprintf(stderr, "[ybar] CreateDispatcherQueueController failed: 0x%08lX\n",
                             static_cast<unsigned long>(hr));
                warned = true;
            }
            return s;
        }
    }
    try {
        s->compositor = wuc::Compositor();
        if (auto blurred =
                s->compositor.try_as<wuc::ICompositorWithBlurredWallpaperBackdropBrush>())
            s->wallpaper = blurred.TryCreateBlurredWallpaperBackdropBrush();
        s->ok = true;
    } catch (const winrt::hresult_error& e) {
        s->compositor = nullptr;
        if (!warned) {
            std::fprintf(stderr, "[ybar] Compositor creation failed: 0x%08X\n",
                         static_cast<unsigned>(e.code()));
            warned = true;
        }
    }
    if (std::getenv("YBAR_DEBUG")) {
        std::fprintf(stderr, "[ybar:composition] compositor=%s wallpaperBrush=%s\n",
                     s->ok ? "ok" : "FAILED", s->wallpaper ? "ok" : "unavailable");
    }
    return s;
}

bool same(const ybar::render::Backdrop& a, const ybar::render::Backdrop& b) {
    return a.origin.x == b.origin.x && a.origin.y == b.origin.y && a.size.x == b.size.x &&
           a.size.y == b.size.y && a.radius == b.radius;
}

} // namespace

class CompositionHostImpl {
public:
    wuc::Desktop::DesktopWindowTarget target{nullptr};
    wuc::ContainerVisual root{nullptr};
    wuc::ContainerVisual backdropLayer{nullptr};
    wuc::SpriteVisual content{nullptr};
    std::vector<wuc::SpriteVisual> pills;
    std::vector<wuc::CompositionRoundedRectangleGeometry> geometries;
    std::vector<ybar::render::Backdrop> current;

    ~CompositionHostImpl() {
        // Detach before the window goes: a target whose HWND is destroyed
        // underneath it is tolerated, but there is no reason to rely on it.
        try {
            if (target) target.Root(nullptr);
        } catch (...) {
        }
    }

    // Changes are batched by the compositor and flushed when the thread's
    // dispatcher next runs, which the daemon's message loop guarantees; the
    // explicit request only brings that forward so the layer lands as close
    // as possible to the Present that follows it. Older compositors lack the
    // method (it is ICompositor6), in which case the batch simply waits.
    void commit() {
        try {
            shared()->compositor.RequestCommitAsync();
        } catch (const winrt::hresult_error&) {
        }
    }
};

std::unique_ptr<CompositionHost> CompositionHost::create(void* hwndRaw, void* swapChainRaw) {
    auto* s = shared();
    if (!s->ok) return nullptr;
    auto impl = std::make_unique<CompositionHostImpl>();
    try {
        auto desktopInterop = s->compositor.as<abi_comp::Desktop::ICompositorDesktopInterop>();
        winrt::check_hresult(desktopInterop->CreateDesktopWindowTarget(
            static_cast<HWND>(hwndRaw), TRUE,
            reinterpret_cast<abi_comp::Desktop::IDesktopWindowTarget**>(
                winrt::put_abi(impl->target))));

        impl->root = s->compositor.CreateContainerVisual();
        impl->root.RelativeSizeAdjustment({1.0f, 1.0f});
        impl->backdropLayer = s->compositor.CreateContainerVisual();
        impl->backdropLayer.RelativeSizeAdjustment({1.0f, 1.0f});

        // The swap chain is the same object the renderer presents to; the
        // composition surface tracks its ResizeBuffers. The content visual
        // fills the window but the brush does NOT stretch: the buffer is
        // drawn at its native size from the top-left, exactly as the
        // DirectComposition content visual did, so the moments when buffer
        // and window disagree (a DPI change before the next Present, or a
        // failed ResizeBuffers) show a short or cropped bar rather than a
        // smeared one. Alignment defaults to centred, hence the zeros.
        auto* swapChain = static_cast<IDXGISwapChain1*>(swapChainRaw);
        auto interop = s->compositor.as<abi_comp::ICompositorInterop>();
        wuc::ICompositionSurface surface{nullptr};
        winrt::check_hresult(interop->CreateCompositionSurfaceForSwapChain(
            static_cast<IUnknown*>(swapChain),
            reinterpret_cast<abi_comp::ICompositionSurface**>(winrt::put_abi(surface))));
        auto brush = s->compositor.CreateSurfaceBrush(surface);
        brush.Stretch(wuc::CompositionStretch::None);
        brush.HorizontalAlignmentRatio(0.0f);
        brush.VerticalAlignmentRatio(0.0f);
        impl->content = s->compositor.CreateSpriteVisual();
        impl->content.RelativeSizeAdjustment({1.0f, 1.0f});
        impl->content.Brush(brush);

        impl->root.Children().InsertAtBottom(impl->backdropLayer);
        impl->root.Children().InsertAtTop(impl->content);
        impl->target.Root(impl->root);
        impl->commit();
    } catch (const winrt::hresult_error& e) {
        std::fprintf(stderr, "[ybar] composition target failed: 0x%08X\n",
                     static_cast<unsigned>(e.code()));
        return nullptr;
    }
    std::unique_ptr<CompositionHost> host(new CompositionHost());
    host->impl_ = std::move(impl);
    return host;
}

CompositionHost::~CompositionHost() = default;

bool CompositionHost::supportsBackdrops() const { return shared()->wallpaper != nullptr; }

bool CompositionHost::backdropsAvailable() { return shared()->wallpaper != nullptr; }

void CompositionHost::rampOpacity(float from, float to, double seconds) {
    auto& impl = *impl_;
    try {
        // A running ramp is replaced, not layered: a fade-out that lands
        // mid fade-in must win, and a property assignment underneath a live
        // animation is ignored by the compositor until it is stopped.
        impl.root.StopAnimation(L"Opacity");
        if (seconds <= 0) {
            impl.root.Opacity(to);
            impl.commit();
            return;
        }
        auto* s = shared();
        auto animation = s->compositor.CreateScalarKeyFrameAnimation();
        auto linear = s->compositor.CreateLinearEasingFunction();
        animation.InsertKeyFrame(0.0f, from, linear);
        animation.InsertKeyFrame(1.0f, to, linear);
        animation.Duration(winrt::Windows::Foundation::TimeSpan{
            static_cast<std::int64_t>(seconds * 10'000'000.0)});
        impl.root.StartAnimation(L"Opacity", animation);
        impl.commit();
    } catch (const winrt::hresult_error& e) {
        std::fprintf(stderr, "[ybar] opacity ramp failed: 0x%08X\n",
                     static_cast<unsigned>(e.code()));
        try {
            impl.root.Opacity(to); // no animation: snap, never stall
        } catch (...) {
        }
    }
}

void CompositionHost::setBackdrops(const std::vector<ybar::render::Backdrop>& backdrops) {
    auto* s = shared();
    auto& impl = *impl_;
    if (!s->wallpaper) return;
    if (backdrops.size() == impl.current.size()) {
        bool unchanged = true;
        for (std::size_t i = 0; i < backdrops.size() && unchanged; ++i)
            unchanged = same(backdrops[i], impl.current[i]);
        if (unchanged) return;
    }
    try {
        // Visuals are reused by index and only re-targeted when their rect
        // moved: a static bar with a ticking clock re-sends the same list at
        // most once a minute and touches nothing.
        while (impl.pills.size() < backdrops.size()) {
            auto geometry = s->compositor.CreateRoundedRectangleGeometry();
            auto pill = s->compositor.CreateSpriteVisual();
            pill.Brush(s->wallpaper);
            pill.Clip(s->compositor.CreateGeometricClip(geometry));
            impl.backdropLayer.Children().InsertAtTop(pill);
            impl.pills.push_back(pill);
            impl.geometries.push_back(geometry);
        }
        while (impl.pills.size() > backdrops.size()) {
            impl.backdropLayer.Children().Remove(impl.pills.back());
            impl.pills.pop_back();
            impl.geometries.pop_back();
        }
        for (std::size_t i = 0; i < backdrops.size(); ++i) {
            const auto& b = backdrops[i];
            if (i < impl.current.size() && same(b, impl.current[i])) continue;
            impl.pills[i].Offset({b.origin.x, b.origin.y, 0.0f});
            impl.pills[i].Size({b.size.x, b.size.y});
            impl.geometries[i].Size({b.size.x, b.size.y});
            impl.geometries[i].CornerRadius({b.radius, b.radius});
        }
        impl.current = backdrops;
        impl.commit();
    } catch (const winrt::hresult_error& e) {
        std::fprintf(stderr, "[ybar] backdrop sync failed: 0x%08X\n",
                     static_cast<unsigned>(e.code()));
    }
}

} // namespace ybar::win
