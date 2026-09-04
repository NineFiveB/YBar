#include "win/popup_surface.h"

#include "win/input.h"
#include "win/system_appearance.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <d3d11.h>
#include <dwmapi.h>
#include <dxgi1_3.h>
#include <dcomp.h>
#include <wrl/client.h>
// clang-format on

#include <cmath>
#include <cstdio>

using Microsoft::WRL::ComPtr;

namespace ybar::win {

namespace {

constexpr wchar_t kPopupClass[] = L"ybar.popup";

LRESULT CALLBACK popupWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);

void registerPopupClassOnce() {
    static bool registered = [] {
        WNDCLASSW windowClass{};
        windowClass.lpfnWndProc = popupWindowProc;
        windowClass.hInstance = GetModuleHandleW(nullptr);
        windowClass.lpszClassName = kPopupClass;
        windowClass.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512)); // IDC_ARROW
        return RegisterClassW(&windowClass) != 0;
    }();
    (void)registered;
}

} // namespace

class PopupSurfaceImpl {
public:
    HWND hwnd = nullptr;
    double scaleValue = 1.0;
    std::unique_ptr<ybar::render::Surface> surface;
    ComPtr<IDCompositionDevice> compositionDevice;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> visual;
    ComPtr<IDCompositionEffectGroup> effect; // carries the open/close opacity
    std::function<void(const MouseEvent&)> onMouse;
    bool visible = false;
    int widthPx = 0;
    int heightPx = 0;
    bool releasingCapture = false; // our own ReleaseCapture, not a steal
    bool trackingLeave = false;    // TME_LEAVE armed, for row hover exit

    ~PopupSurfaceImpl() {
        if (hwnd) {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            DestroyWindow(hwnd);
        }
    }

    void dispatchMouse(MouseEvent::Kind kind, LPARAM lParam, const char* button,
                       int scrollDelta = 0) {
        if (!onMouse) return;
        MouseEvent event;
        event.kind = kind;
        event.x = static_cast<double>(GET_X_LPARAM(lParam)) / scaleValue;
        event.y = static_cast<double>(GET_Y_LPARAM(lParam)) / scaleValue;
        event.button = button;
        event.modifier = currentModifier();
        event.scrollDelta = scrollDelta;
        onMouse(event);
    }
};

namespace {

LRESULT CALLBACK popupWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* impl = reinterpret_cast<PopupSurfaceImpl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
        case WM_NCHITTEST:
            return HTCLIENT;
        case WM_MOUSEACTIVATE:
            return MA_NOACTIVATE;
        case WM_LBUTTONDOWN:
            // Down + capture + Move exist so popup sliders can be pressed
            // and scrubbed exactly like bar sliders (spec 3.9) — the
            // reference routes popup presses through the shared drag
            // machinery.
            if (impl) {
                SetCapture(hwnd);
                impl->dispatchMouse(MouseEvent::Kind::Down, lParam, "left");
            }
            return 0;
        case WM_MOUSEMOVE:
            if (impl) {
                // Arm leave tracking so a row's hover can be released when the
                // pointer exits the panel. Without this the last row the
                // pointer touched stays lit after it leaves, because a popup
                // gets no other signal that the pointer is gone.
                if (!impl->trackingLeave) {
                    TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0};
                    TrackMouseEvent(&track);
                    impl->trackingLeave = true;
                }
                impl->dispatchMouse(MouseEvent::Kind::Move, lParam, "left");
            }
            return 0;
        case WM_MOUSELEAVE:
            if (impl) {
                impl->trackingLeave = false;
                // Same defence the bar carries (spec 6): the compositor can
                // post a leave the pointer never performed when the window is
                // touched under a stationary cursor, which would flap row
                // hover. Believe it only when the cursor is really outside.
                POINT cursor{};
                RECT bounds{};
                if (GetCursorPos(&cursor) && GetWindowRect(hwnd, &bounds) &&
                    PtInRect(&bounds, cursor)) {
                    TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE, hwnd, 0};
                    TrackMouseEvent(&track);
                    impl->trackingLeave = true;
                    return 0;
                }
                MouseEvent event;
                event.kind = MouseEvent::Kind::Leave;
                event.modifier = currentModifier();
                if (impl->onMouse) impl->onMouse(event);
            }
            return 0;
        case WM_LBUTTONUP:
            if (impl) {
                if (GetCapture() == hwnd) {
                    impl->releasingCapture = true;
                    ReleaseCapture();
                    impl->releasingCapture = false;
                }
                impl->dispatchMouse(MouseEvent::Kind::Up, lParam, "left");
            }
            return 0;
        case WM_CAPTURECHANGED:
            if (impl && !impl->releasingCapture) {
                POINT point{};
                GetCursorPos(&point);
                ScreenToClient(hwnd, &point);
                impl->dispatchMouse(MouseEvent::Kind::Up, MAKELPARAM(point.x, point.y),
                                    "left");
            }
            return 0;
        case WM_RBUTTONUP:
            if (impl) impl->dispatchMouse(MouseEvent::Kind::Up, lParam, "right");
            return 0;
        case WM_MBUTTONUP:
            if (impl) impl->dispatchMouse(MouseEvent::Kind::Up, lParam, "other");
            return 0;
        case WM_MOUSEWHEEL:
            if (impl) {
                POINT point{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)};
                ScreenToClient(hwnd, &point);
                impl->dispatchMouse(MouseEvent::Kind::Scroll, MAKELPARAM(point.x, point.y),
                                    "left", GET_WHEEL_DELTA_WPARAM(wParam) / WHEEL_DELTA);
            }
            return 0;
        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

} // namespace

std::unique_ptr<PopupSurface> PopupSurface::create(ybar::render::Renderer& renderer,
                                                   double scale) {
    registerPopupClassOnce();
    auto impl = std::make_unique<PopupSurfaceImpl>();
    impl->scaleValue = scale;

    impl->hwnd = CreateWindowExW(
        WS_EX_NOREDIRECTIONBITMAP | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
        kPopupClass, L"ybar-popup", WS_POPUP, 0, 0, 64, 64, nullptr, nullptr,
        GetModuleHandleW(nullptr), nullptr);
    if (!impl->hwnd) return nullptr;
    SetWindowLongPtrW(impl->hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(impl.get()));

    impl->surface = renderer.createSurface(64, 64);
    if (!impl->surface) return nullptr;
    impl->widthPx = 64;
    impl->heightPx = 64;

    auto* swapChain = static_cast<IDXGISwapChain1*>(impl->surface->compositionSurface());
    ComPtr<ID3D11Device> device;
    if (FAILED(swapChain->GetDevice(IID_PPV_ARGS(&device)))) return nullptr;
    ComPtr<IDXGIDevice> dxgiDevice;
    device.As(&dxgiDevice);
    if (FAILED(DCompositionCreateDevice(dxgiDevice.Get(),
                                        IID_PPV_ARGS(&impl->compositionDevice))) ||
        FAILED(impl->compositionDevice->CreateTargetForHwnd(impl->hwnd, TRUE, &impl->target)) ||
        FAILED(impl->compositionDevice->CreateVisual(&impl->visual)))
        return nullptr;
    impl->visual->SetContent(swapChain);
    // No transform: the target composes in the window's physical-pixel space
    // (see bar_surface.cpp for the full note).
    // An effect group carries the open/close opacity. Created once and left
    // at 1.0, so a popup that never asks for a fade composes exactly as it
    // did before this existed.
    if (SUCCEEDED(impl->compositionDevice->CreateEffectGroup(&impl->effect))) {
        impl->effect->SetOpacity(1.0f);
        impl->visual->SetEffect(impl->effect.Get());
    }
    impl->target->SetRoot(impl->visual.Get());
    impl->compositionDevice->Commit();

    std::unique_ptr<PopupSurface> popup(new PopupSurface());
    popup->impl_ = std::move(impl);
    return popup;
}

PopupSurface::~PopupSurface() = default;

void PopupSurface::present(ybar::model::Size panelSize, const ybar::model::Rect& anchor,
                           char align, bool below, double yOffset, double fadeInFrames) {
    const double scale = impl_->scaleValue;
    const int widthPx = static_cast<int>(std::lround(panelSize.width * scale));
    const int heightPx = static_cast<int>(std::lround(panelSize.height * scale));

    double x = anchor.x; // left-aligned default
    if (align == 'c') x = anchor.midX() - widthPx / 2.0;
    else if (align == 'r') x = anchor.maxX() - widthPx;
    double y = below ? anchor.maxY() + yOffset * scale
                     : anchor.y - heightPx - yOffset * scale;

    // Clamp into the anchor's monitor (spec 6): an item near a screen edge
    // would otherwise push half its popup onto the neighbouring display, or
    // off the desktop entirely.
    const POINT anchorPoint{static_cast<LONG>(std::lround(anchor.midX())),
                            static_cast<LONG>(std::lround(anchor.midY()))};
    MONITORINFO info{sizeof(info)};
    if (GetMonitorInfoW(MonitorFromPoint(anchorPoint, MONITOR_DEFAULTTONEAREST), &info)) {
        const auto& bounds = info.rcMonitor;
        // Stop short of the edge instead of sitting flush against it. A
        // clamped popup otherwise touches the bezel while an unclamped one
        // does not: the calendar right-aligns to its own pill and so inherits
        // the inset the bar's rightmost pill already leaves, but the tray
        // popup is centred on an item near the edge, overflows, and used to be
        // pinned hard to bounds.right. This margin is that same inset, so a
        // clamped popup lines up with one that never needed clamping. It is a
        // theme-spacing constant, not a derived one: the bar's padding lives
        // in Lua and never reaches this layer.
        constexpr double kEdgeMarginPt = 7.0;
        const double margin = kEdgeMarginPt * scale;
        const double maxX = bounds.right - margin - widthPx;
        const double minX = bounds.left + margin;
        if (x > maxX) x = maxX;
        // Applied second on purpose: a popup wider than the monitor then lands
        // on the left margin and overflows to the right, instead of the clamp
        // above shoving it off-screen to the left.
        if (x < minX) x = minX;
        // Vertical flip rather than a slide: a panel overlapping its own host
        // swallows the clicks meant for it.
        if (y + heightPx > bounds.bottom) y = anchor.y - heightPx - yOffset * scale;
        if (y < bounds.top) y = anchor.maxY() + yOffset * scale;
    }

    if (widthPx != impl_->widthPx || heightPx != impl_->heightPx) {
        impl_->surface->resize(widthPx, heightPx);
        impl_->widthPx = widthPx;
        impl_->heightPx = heightPx;
    }
    SetWindowPos(impl_->hwnd, HWND_TOPMOST, static_cast<int>(std::lround(x)),
                 static_cast<int>(std::lround(y)), widthPx, heightPx, SWP_NOACTIVATE);
    if (!impl_->visible) {
        ShowWindow(impl_->hwnd, SW_SHOWNOACTIVATE);
        impl_->visible = true;
        // Only on the edge: fadeIn every frame would restart the ramp and the
        // panel would never finish appearing. This also resets the opacity a
        // previous fade-out left at 0.
        fadeIn(fadeInFrames);
    }
    impl_->compositionDevice->Commit();
}

void PopupSurface::setBackdrop(bool acrylic, double cornerRadius) {
    // spec 7.6: Acrylic behind the panel when popup.blur_radius > 0, plus a
    // rounded backdrop so the plate does not square off the painted corners.
    // Gated on Transparency effects — off means the panel is composited opaque
    // (see buildPopupScene), so an Acrylic material would not match.
    const auto backdrop = static_cast<int>(
        acrylic && systemTransparencyEnabled() ? DWMSBT_TRANSIENTWINDOW : DWMSBT_NONE);
    DwmSetWindowAttribute(impl_->hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, sizeof(backdrop));
    const BOOL dark = TRUE;
    DwmSetWindowAttribute(impl_->hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
    const auto corner = static_cast<int>(cornerRadius <= 0   ? DWMWCP_DONOTROUND
                                         : cornerRadius < 6  ? DWMWCP_ROUNDSMALL
                                                             : DWMWCP_ROUND);
    DwmSetWindowAttribute(impl_->hwnd, DWMWA_WINDOW_CORNER_PREFERENCE, &corner, sizeof(corner));
}

namespace {

// One linear ramp between two opacities. AddCubic with only the linear term
// set is the shortest way to say "go from a to b over d seconds" through
// IDCompositionAnimation, and End() pins the value afterwards so a dropped
// animation holds its endpoint instead of snapping back.
void rampOpacity(IDCompositionDevice& device, IDCompositionEffectGroup& effect, float from,
                 float to, double seconds) {
    ComPtr<IDCompositionAnimation> animation;
    if (FAILED(device.CreateAnimation(&animation))) {
        effect.SetOpacity(to); // no animation available: snap, never stall
        return;
    }
    animation->AddCubic(0.0, from, static_cast<float>((to - from) / seconds), 0.0f, 0.0f);
    animation->End(seconds, to);
    effect.SetOpacity(animation.Get());
}

} // namespace

void PopupSurface::fadeIn(double frames) {
    if (!impl_->effect) return;
    if (frames <= 0) {
        impl_->effect->SetOpacity(1.0f);
        impl_->compositionDevice->Commit();
        return;
    }
    rampOpacity(*impl_->compositionDevice.Get(), *impl_->effect.Get(), 0.0f, 1.0f,
                frames / 60.0);
    impl_->compositionDevice->Commit();
}

void PopupSurface::fadeOut(double frames) {
    if (!impl_->effect || !impl_->visible) return;
    if (frames <= 0) {
        impl_->effect->SetOpacity(0.0f);
        impl_->compositionDevice->Commit();
        return;
    }
    rampOpacity(*impl_->compositionDevice.Get(), *impl_->effect.Get(), 1.0f, 0.0f,
                frames / 60.0);
    impl_->compositionDevice->Commit();
}

void PopupSurface::hide() {
    if (!impl_->visible) return;
    ShowWindow(impl_->hwnd, SW_HIDE);
    impl_->visible = false;
    // Leave the opacity where a fade-out left it and reset on the next show
    // instead: clearing it here would flash the panel back to full opacity
    // for the frame between the fade ending and the window hiding.
}

ybar::render::Surface& PopupSurface::renderSurface() { return *impl_->surface; }
double PopupSurface::scale() const { return impl_->scaleValue; }
void PopupSurface::setMouseHandler(std::function<void(const MouseEvent&)> handler) {
    impl_->onMouse = std::move(handler);
}
void* PopupSurface::hwnd() const { return impl_->hwnd; }

} // namespace ybar::win
