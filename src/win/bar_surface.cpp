#include "win/bar_surface.h"

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
#include <cstdlib>

using Microsoft::WRL::ComPtr;

namespace ybar::win {

using ybar::model::BarLevel;
using ybar::model::BarPosition;
using ybar::model::BarSettings;

namespace {

constexpr wchar_t kBarClass[] = L"ybar.bar";

const char* currentModifier() {
    // Priority order shift > ctrl > alt > cmd(Win) — contract (spec 3.5).
    if (GetKeyState(VK_SHIFT) < 0) return "shift";
    if (GetKeyState(VK_CONTROL) < 0) return "ctrl";
    if (GetKeyState(VK_MENU) < 0) return "alt";
    if (GetKeyState(VK_LWIN) < 0 || GetKeyState(VK_RWIN) < 0) return "cmd";
    return "none";
}

LRESULT CALLBACK barWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);

void registerClassOnce() {
    static bool registered = [] {
        WNDCLASSW windowClass{};
        windowClass.lpfnWndProc = barWindowProc;
        windowClass.hInstance = GetModuleHandleW(nullptr);
        windowClass.lpszClassName = kBarClass;
        windowClass.hCursor = LoadCursorW(nullptr, MAKEINTRESOURCEW(32512)); // IDC_ARROW
        return RegisterClassW(&windowClass) != 0;
    }();
    (void)registered;
}

} // namespace

class BarSurfaceImpl {
public:
    HWND hwnd = nullptr;
    MonitorInfo monitorInfo;
    std::unique_ptr<ybar::render::Surface> surface;
    ComPtr<IDCompositionDevice> compositionDevice;
    ComPtr<IDCompositionTarget> target;
    ComPtr<IDCompositionVisual> visual;
    double logicalW = 0;
    double logicalH = 0;
    std::function<void(const MouseEvent&)> onMouse;
    bool trackingLeave = false;

    ~BarSurfaceImpl() {
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
        event.x = static_cast<double>(GET_X_LPARAM(lParam)) / monitorInfo.scale;
        event.y = static_cast<double>(GET_Y_LPARAM(lParam)) / monitorInfo.scale;
        event.button = button;
        event.modifier = currentModifier();
        event.scrollDelta = scrollDelta;
        onMouse(event);
    }

    RECT frameFor(const BarSettings& settings) const {
        const double scale = monitorInfo.scale;
        const auto& mon = monitorInfo.frame;
        const double margin = settings.margin * scale;
        const double height = settings.height * scale;
        const double yOffset = settings.yOffset * scale;
        RECT rect;
        rect.left = static_cast<LONG>(std::lround(mon.x + margin));
        rect.right = static_cast<LONG>(std::lround(mon.maxX() - margin));
        if (settings.position == BarPosition::Top) {
            rect.top = static_cast<LONG>(std::lround(mon.y + yOffset));
        } else {
            rect.top = static_cast<LONG>(std::lround(mon.maxY() - height - yOffset));
        }
        rect.bottom = rect.top + static_cast<LONG>(std::lround(height));
        return rect;
    }
};

namespace {

HWND g_broadcastTarget = nullptr;

LRESULT CALLBACK barWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    auto* impl = reinterpret_cast<BarSurfaceImpl*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
    switch (msg) {
        case WM_POWERBROADCAST:
        case WM_FONTCHANGE:
            // Forward broadcasts to the daemon's message-only mailbox, which
            // never receives them directly (spec 5 note).
            if (g_broadcastTarget) PostMessageW(g_broadcastTarget, msg, wParam, lParam);
            return msg == WM_POWERBROADCAST ? TRUE : 0;
        case WM_NCHITTEST:
            return HTCLIENT; // never draggable; full-frame input (spec 6)
        case WM_MOUSEACTIVATE:
            return MA_NOACTIVATE;
        case WM_LBUTTONDOWN:
            if (impl) impl->dispatchMouse(MouseEvent::Kind::Down, lParam, "left");
            return 0;
        case WM_LBUTTONUP:
            if (impl) impl->dispatchMouse(MouseEvent::Kind::Up, lParam, "left");
            return 0;
        case WM_RBUTTONUP:
            if (impl) impl->dispatchMouse(MouseEvent::Kind::Up, lParam, "right");
            return 0;
        case WM_MBUTTONUP:
            if (impl) impl->dispatchMouse(MouseEvent::Kind::Up, lParam, "other");
            return 0;
        case WM_MOUSEMOVE:
            if (impl) {
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
                MouseEvent event;
                event.kind = MouseEvent::Kind::Leave;
                event.modifier = currentModifier();
                if (impl->onMouse) impl->onMouse(event);
            }
            return 0;
        case WM_MOUSEWHEEL:
            if (impl) {
                POINT point{GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam)}; // screen coords
                ScreenToClient(hwnd, &point);
                const int delta = GET_WHEEL_DELTA_WPARAM(wParam) / WHEEL_DELTA;
                impl->dispatchMouse(MouseEvent::Kind::Scroll, MAKELPARAM(point.x, point.y),
                                    "left", delta);
            }
            return 0;
        default:
            return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
}

} // namespace

std::unique_ptr<BarSurface> BarSurface::create(ybar::render::Renderer& renderer,
                                               const MonitorInfo& monitor,
                                               const BarSettings& settings) {
    registerClassOnce();
    auto impl = std::make_unique<BarSurfaceImpl>();
    impl->monitorInfo = monitor;

    const RECT frame = impl->frameFor(settings);
    const int widthPx = frame.right - frame.left;
    const int heightPx = frame.bottom - frame.top;

    DWORD exStyle = WS_EX_NOREDIRECTIONBITMAP | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW;
    if (settings.topmost != BarLevel::Off) exStyle |= WS_EX_TOPMOST;
    impl->hwnd = CreateWindowExW(exStyle, kBarClass, L"ybar", WS_POPUP, frame.left, frame.top,
                                 widthPx, heightPx, nullptr, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
    if (!impl->hwnd) {
        std::fprintf(stderr, "[ybar] bar window creation failed\n");
        return nullptr;
    }
    SetWindowLongPtrW(impl->hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(impl.get()));

    impl->surface = renderer.createSurface(widthPx, heightPx);
    if (!impl->surface) return nullptr;

    // DirectComposition: device -> target(hwnd) -> visual -> swap chain.
    auto* d3dDevice = static_cast<ID3D11Device*>(nullptr);
    {
        // Recover the ID3D11Device from the renderer's swap chain.
        auto* swapChain = static_cast<IDXGISwapChain1*>(impl->surface->compositionSurface());
        ComPtr<ID3D11Device> device;
        if (FAILED(swapChain->GetDevice(IID_PPV_ARGS(&device)))) return nullptr;
        ComPtr<IDXGIDevice> dxgiDevice;
        device.As(&dxgiDevice);
        if (FAILED(DCompositionCreateDevice(dxgiDevice.Get(),
                                            IID_PPV_ARGS(&impl->compositionDevice))))
            return nullptr;
        d3dDevice = device.Get();
        (void)d3dDevice;
    }
    if (FAILED(impl->compositionDevice->CreateTargetForHwnd(impl->hwnd, TRUE, &impl->target)) ||
        FAILED(impl->compositionDevice->CreateVisual(&impl->visual)))
        return nullptr;
    impl->visual->SetContent(static_cast<IDXGISwapChain1*>(impl->surface->compositionSurface()));
    // A composition target composes in the WINDOW's coordinate space, which is
    // physical pixels for a PerMonitorV2 process — so a physical-pixel buffer
    // maps 1:1 with no transform. (An earlier 96/dpi counter-scale shrank the
    // scene to a quarter of the window on a 200% monitor: full-width window,
    // half-width paint. YBAR_DCOMP_SCALE overrides for diagnosis.)
    if (const char* override = std::getenv("YBAR_DCOMP_SCALE")) {
        const auto factor = static_cast<float>(std::atof(override));
        if (factor > 0) {
            D2D_MATRIX_3X2_F matrix{};
            matrix._11 = factor;
            matrix._22 = factor;
            impl->visual->SetTransform(matrix);
        }
    }
    impl->target->SetRoot(impl->visual.Get());
    impl->compositionDevice->Commit();

    // The window's own DPI is authoritative under PerMonitorV2 — prefer it
    // over the enumeration-time monitor scale.
    const UINT windowDpi = GetDpiForWindow(impl->hwnd);
    if (windowDpi != 0) impl->monitorInfo.scale = static_cast<double>(windowDpi) / 96.0;
    impl->logicalW = widthPx / impl->monitorInfo.scale;
    impl->logicalH = heightPx / impl->monitorInfo.scale;

    if (std::getenv("YBAR_DEBUG")) {
        std::fprintf(stderr,
                     "[ybar:surface] monitorFrame=%.0fx%.0f enumScale=%.2f windowDpi=%u "
                     "scale=%.2f widthPx=%d logicalW=%.0f\n",
                     monitor.frame.width, monitor.frame.height, monitor.scale, windowDpi,
                     impl->monitorInfo.scale, widthPx, impl->logicalW);
        std::fflush(stderr);
    }

    ShowWindow(impl->hwnd, settings.hidden ? SW_HIDE : SW_SHOWNOACTIVATE);
    SetWindowPos(impl->hwnd,
                 settings.topmost == BarLevel::Off ? HWND_BOTTOM : HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);

    std::unique_ptr<BarSurface> bar(new BarSurface());
    bar->impl_ = std::move(impl);
    return bar;
}

BarSurface::~BarSurface() = default;

void BarSurface::applySettings(const BarSettings& settings) {
    const RECT frame = impl_->frameFor(settings);
    const int widthPx = frame.right - frame.left;
    const int heightPx = frame.bottom - frame.top;
    SetWindowPos(impl_->hwnd,
                 settings.topmost == BarLevel::Off ? HWND_BOTTOM : HWND_TOPMOST, frame.left,
                 frame.top, widthPx, heightPx, SWP_NOACTIVATE);
    impl_->surface->resize(widthPx, heightPx);
    impl_->logicalW = widthPx / impl_->monitorInfo.scale;
    impl_->logicalH = heightPx / impl_->monitorInfo.scale;
    ShowWindow(impl_->hwnd, settings.hidden ? SW_HIDE : SW_SHOWNOACTIVATE);
    impl_->compositionDevice->Commit();
}

void BarSurface::setMouseHandler(std::function<void(const MouseEvent&)> handler) {
    impl_->onMouse = std::move(handler);
}

void BarSurface::setBroadcastTarget(void* messageWindow) {
    g_broadcastTarget = static_cast<HWND>(messageWindow);
}

ybar::render::Surface& BarSurface::renderSurface() { return *impl_->surface; }
const MonitorInfo& BarSurface::monitor() const { return impl_->monitorInfo; }
void* BarSurface::hwnd() const { return impl_->hwnd; }

ybar::model::Point BarSurface::screenOrigin() const {
    RECT rect{};
    GetWindowRect(impl_->hwnd, &rect);
    return {static_cast<double>(rect.left), static_cast<double>(rect.top)};
}
double BarSurface::scale() const { return impl_->monitorInfo.scale; }
double BarSurface::logicalWidth() const { return impl_->logicalW; }
double BarSurface::logicalHeight() const { return impl_->logicalH; }

} // namespace ybar::win
