#include "win/bar_surface.h"

#include "win/input.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <d3d11.h>
#include <dxgi1_3.h>
#include <dcomp.h>
#include <shellapi.h>
#include <shobjidl_core.h> // IVirtualDesktopManager (sticky pinning)
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
    // Kept so WM_DPICHANGED and the topmost re-assertion can recompute the
    // frame without a round trip to the daemon.
    BarSettings settings;
    bool elevatedForFullscreen = false;
    bool appBarRegistered = false;
    ComPtr<IVirtualDesktopManager> desktopManager;
    bool warnedSticky = false;

    ~BarSurfaceImpl() {
        removeAppBar();
        if (hwnd) {
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            DestroyWindow(hwnd);
        }
    }

    // Effective z-order: fullscreen elevation overrides a configured
    // topmost=off, which is otherwise pinned to the bottom of the z-order.
    HWND zOrder() const {
        if (elevatedForFullscreen) return HWND_TOPMOST;
        return settings.topmost == BarLevel::Off ? HWND_BOTTOM : HWND_TOPMOST;
    }

    // Space reservation for users without a tiling WM (spec 6.1). The appbar
    // owns the strip; komorebi mode reserves through komorebi instead, and
    // the two are mutually exclusive by construction.
    void applyAppBar(const RECT& frame) {
        if (settings.reserve != ybar::model::ReserveMode::AppBar) {
            removeAppBar();
            return;
        }
        APPBARDATA data{};
        data.cbSize = sizeof(data);
        data.hWnd = hwnd;
        if (!appBarRegistered) {
            if (!SHAppBarMessage(ABM_NEW, &data)) return;
            appBarRegistered = true;
        }
        data.uEdge = settings.position == BarPosition::Top ? ABE_TOP : ABE_BOTTOM;
        data.rc = frame;
        // The shell may push the proposed rect aside for other appbars; adopt
        // whatever it returns rather than fighting it.
        SHAppBarMessage(ABM_QUERYPOS, &data);
        const LONG height = frame.bottom - frame.top;
        if (data.uEdge == ABE_TOP) data.rc.bottom = data.rc.top + height;
        else data.rc.top = data.rc.bottom - height;
        SHAppBarMessage(ABM_SETPOS, &data);
        SetWindowPos(hwnd, zOrder(), data.rc.left, data.rc.top, data.rc.right - data.rc.left,
                     data.rc.bottom - data.rc.top, SWP_NOACTIVATE);
    }

    // sticky=on: keep the bar on whatever virtual desktop the user is on.
    // True pinning lives behind an undocumented, build-fragile interface
    // (IVirtualDesktopPinnedApps); the documented IVirtualDesktopManager can
    // only move a window, so that is what this does — re-driven from the
    // daemon's 1 s tick. With komorebi the point is mostly moot: its
    // workspaces all live on one Windows desktop.
    void applyStickyPinning() {
        if (!settings.sticky) return;
        followCurrentDesktop();
    }

    void followCurrentDesktop() {
        if (!settings.sticky || !hwnd) return;
        if (!desktopManager) {
            if (FAILED(CoCreateInstance(CLSID_VirtualDesktopManager, nullptr,
                                        CLSCTX_INPROC_SERVER,
                                        IID_PPV_ARGS(&desktopManager)))) {
                if (!warnedSticky) {
                    warnedSticky = true;
                    std::fprintf(stderr,
                                 "[ybar] sticky=on unavailable: no virtual desktop manager\n");
                }
                return;
            }
        }
        BOOL onCurrent = TRUE;
        if (FAILED(desktopManager->IsWindowOnCurrentVirtualDesktop(hwnd, &onCurrent)) ||
            onCurrent)
            return;
        GUID current{};
        // Moving to the desktop of a window that IS current is the only
        // documented way to name it; the foreground window serves.
        const HWND reference = GetForegroundWindow();
        if (!reference ||
            FAILED(desktopManager->GetWindowDesktopId(reference, &current)) ||
            FAILED(desktopManager->MoveWindowToDesktop(hwnd, current))) {
            if (!warnedSticky) {
                warnedSticky = true;
                std::fprintf(stderr, "[ybar] sticky=on could not follow the virtual desktop\n");
            }
        }
    }

    void removeAppBar() {
        if (!appBarRegistered) return;
        APPBARDATA data{};
        data.cbSize = sizeof(data);
        data.hWnd = hwnd;
        SHAppBarMessage(ABM_REMOVE, &data);
        appBarRegistered = false;
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
        case WM_DISPLAYCHANGE:
            // Forward broadcasts to the daemon's message-only mailbox, which
            // never receives them directly (spec 5 note). The daemon debounces
            // WM_DISPLAYCHANGE and rebuilds every surface.
            if (g_broadcastTarget) PostMessageW(g_broadcastTarget, msg, wParam, lParam);
            return msg == WM_POWERBROADCAST ? TRUE : 0;
        case WM_DPICHANGED:
            // PerMonitorV2: adopt the new DPI, recompute the frame from
            // settings (the suggested rect assumes a normal window), and let
            // the daemon swap in the glyph atlas for the new scale.
            if (impl) {
                impl->monitorInfo.scale = static_cast<double>(HIWORD(wParam)) / 96.0;
                const RECT frame = impl->frameFor(impl->settings);
                const int widthPx = frame.right - frame.left;
                const int heightPx = frame.bottom - frame.top;
                SetWindowPos(hwnd, impl->zOrder(), frame.left, frame.top, widthPx, heightPx,
                             SWP_NOACTIVATE);
                impl->surface->resize(widthPx, heightPx);
                impl->logicalW = widthPx / impl->monitorInfo.scale;
                impl->logicalH = heightPx / impl->monitorInfo.scale;
                impl->compositionDevice->Commit();
                if (g_broadcastTarget) PostMessageW(g_broadcastTarget, msg, wParam, 0);
            }
            return 0;
        case WM_WINDOWPOSCHANGING:
            // topmost=off means "stay under everything" — but any window
            // activation reshuffles the z-order, so the position has to be
            // re-asserted on every change (spec 6).
            if (impl && impl->zOrder() == HWND_BOTTOM) {
                auto* position = reinterpret_cast<WINDOWPOS*>(lParam);
                position->hwndInsertAfter = HWND_BOTTOM;
                position->flags &= ~SWP_NOZORDER;
            }
            return 0;
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

    impl->settings = settings;
    ShowWindow(impl->hwnd, settings.hidden ? SW_HIDE : SW_SHOWNOACTIVATE);
    SetWindowPos(impl->hwnd, impl->zOrder(), 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    impl->applyAppBar(frame);
    impl->applyStickyPinning();

    std::unique_ptr<BarSurface> bar(new BarSurface());
    bar->impl_ = std::move(impl);
    return bar;
}

BarSurface::~BarSurface() = default;

void BarSurface::applySettings(const BarSettings& settings) {
    const bool stickyChanged = impl_->settings.sticky != settings.sticky;
    impl_->settings = settings;
    const RECT frame = impl_->frameFor(settings);
    const int widthPx = frame.right - frame.left;
    const int heightPx = frame.bottom - frame.top;
    SetWindowPos(impl_->hwnd, impl_->zOrder(), frame.left, frame.top, widthPx, heightPx,
                 SWP_NOACTIVATE);
    impl_->surface->resize(widthPx, heightPx);
    impl_->logicalW = widthPx / impl_->monitorInfo.scale;
    impl_->logicalH = heightPx / impl_->monitorInfo.scale;
    ShowWindow(impl_->hwnd, settings.hidden ? SW_HIDE : SW_SHOWNOACTIVATE);
    impl_->applyAppBar(frame);
    if (stickyChanged) impl_->applyStickyPinning();
    impl_->compositionDevice->Commit();
}

void BarSurface::followCurrentDesktop() { impl_->followCurrentDesktop(); }

void BarSurface::setFullscreenElevation(bool elevated) {
    if (impl_->elevatedForFullscreen == elevated) return;
    impl_->elevatedForFullscreen = elevated;
    SetWindowPos(impl_->hwnd, impl_->zOrder(), 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

bool BarSurface::monitorHasFullscreenWindow() const {
    // Borderless-fullscreen games never change the shell notification state,
    // so the reliable test is geometry: the foreground window covering this
    // monitor exactly (spec 6).
    const HWND foreground = GetForegroundWindow();
    if (!foreground || foreground == impl_->hwnd) return false;
    if (MonitorFromWindow(foreground, MONITOR_DEFAULTTONEAREST) !=
        MonitorFromWindow(impl_->hwnd, MONITOR_DEFAULTTONEAREST))
        return false;
    // The desktop and the shell tray always cover the monitor; neither is a
    // fullscreen app.
    wchar_t className[64] = L"";
    if (GetClassNameW(foreground, className, 64)) {
        if (wcscmp(className, L"WorkerW") == 0 || wcscmp(className, L"Progman") == 0 ||
            wcscmp(className, L"Shell_TrayWnd") == 0)
            return false;
    }
    RECT window{};
    if (!GetWindowRect(foreground, &window)) return false;
    const auto& monitor = impl_->monitorInfo.frame;
    // `near` is still a legacy macro in windef.h — do not name it that.
    const auto matches = [](LONG a, double b) { return std::abs(a - b) < 2.0; };
    return matches(window.left, monitor.x) && matches(window.top, monitor.y) &&
           matches(window.right, monitor.maxX()) && matches(window.bottom, monitor.maxY());
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
