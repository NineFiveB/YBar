#include "win/popup_surface.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <d3d11.h>
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

const char* popupModifier() {
    if (GetKeyState(VK_SHIFT) < 0) return "shift";
    if (GetKeyState(VK_CONTROL) < 0) return "ctrl";
    if (GetKeyState(VK_MENU) < 0) return "alt";
    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) return "cmd";
    return "none";
}

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
    std::function<void(const MouseEvent&)> onMouse;
    bool visible = false;
    int widthPx = 0;
    int heightPx = 0;

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
        event.modifier = popupModifier();
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
        case WM_LBUTTONUP:
            if (impl) impl->dispatchMouse(MouseEvent::Kind::Up, lParam, "left");
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
    impl->target->SetRoot(impl->visual.Get());
    impl->compositionDevice->Commit();

    std::unique_ptr<PopupSurface> popup(new PopupSurface());
    popup->impl_ = std::move(impl);
    return popup;
}

PopupSurface::~PopupSurface() = default;

void PopupSurface::present(ybar::model::Size panelSize, const ybar::model::Rect& anchor,
                           char align, bool below, double yOffset) {
    const double scale = impl_->scaleValue;
    const int widthPx = static_cast<int>(std::lround(panelSize.width * scale));
    const int heightPx = static_cast<int>(std::lround(panelSize.height * scale));

    double x = anchor.x; // left-aligned default
    if (align == 'c') x = anchor.midX() - widthPx / 2.0;
    else if (align == 'r') x = anchor.maxX() - widthPx;
    const double y = below ? anchor.maxY() + yOffset * scale
                           : anchor.y - heightPx - yOffset * scale;

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
    }
    impl_->compositionDevice->Commit();
}

void PopupSurface::hide() {
    if (!impl_->visible) return;
    ShowWindow(impl_->hwnd, SW_HIDE);
    impl_->visible = false;
}

ybar::render::Surface& PopupSurface::renderSurface() { return *impl_->surface; }
double PopupSurface::scale() const { return impl_->scaleValue; }
void PopupSurface::setMouseHandler(std::function<void(const MouseEvent&)> handler) {
    impl_->onMouse = std::move(handler);
}
void* PopupSurface::hwnd() const { return impl_->hwnd; }

} // namespace ybar::win
