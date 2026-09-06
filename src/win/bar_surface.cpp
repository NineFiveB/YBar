#include "win/bar_surface.h"

#include "win/composition_host.h"
#include "win/input.h"
#include "win/system_appearance.h"

// clang-format off
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <windowsx.h>
#include <dwmapi.h>
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

// Private message the shell uses to deliver ABN_* appbar notifications
// (registered via APPBARDATA.uCallbackMessage — without it every ABN_*
// arrives as WM_NULL and is lost).
constexpr UINT kAppBarCallback = WM_APP + 1;

// The SDK declares IVirtualDesktopManager but no coclass, so the CLSID has to
// be spelled out: {AA509086-5CA9-4C25-8F95-589D3C07B48A}.
constexpr CLSID kClsidVirtualDesktopManager = {
    0xaa509086, 0x5ca9, 0x4c25, {0x8f, 0x95, 0x58, 0x9d, 0x3c, 0x07, 0xb4, 0x8a}};

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
    std::unique_ptr<CompositionHost> host; // composition tree over `surface`
    double logicalW = 0;
    double logicalH = 0;
    std::function<void(const MouseEvent&)> onMouse;
    bool trackingLeave = false;
    // Kept so WM_DPICHANGED and the topmost re-assertion can recompute the
    // frame without a round trip to the daemon.
    BarSettings settings;
    bool elevatedForFullscreen = false;
    // Auto-hide this monitor's bar while a fullscreen window covers it
    // (fullscreen_show=off). Independent of the user's own hidden= toggle;
    // the window hides when EITHER asks.
    bool hiddenForFullscreen = false;
    bool appBarRegistered = false;
    ComPtr<IVirtualDesktopManager> desktopManager;
    bool warnedSticky = false;
    // Last-applied state: renderAll re-applies settings every frame (up to
    // 60 Hz under animation), so repositioning and appbar negotiation must
    // be no-ops when nothing changed.
    RECT lastAppliedFrame{};
    HWND lastZ = reinterpret_cast<HWND>(-2); // neither TOPMOST nor BOTTOM
    bool lastHidden = false;
    RECT appBarProposed{};   // last rect offered to ABM_QUERYPOS
    RECT appBarNegotiated{}; // what the shell granted for it
    bool releasingCapture = false; // our own ReleaseCapture, not a steal

    ~BarSurfaceImpl() {
        removeAppBar();
        host.reset(); // detach the composition target before its window goes
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

    // Show/hide from the OR of the user's hidden= toggle and the fullscreen
    // auto-hide. lastHidden tracks the EFFECTIVE state so the per-frame
    // applyFrame call is a no-op when nothing changed. (create() shows the
    // window and seeds lastHidden before this is first reached.)
    void applyVisibility() {
        const bool hide = settings.hidden || hiddenForFullscreen;
        if (hide == lastHidden) return;
        ShowWindow(hwnd, hide ? SW_HIDE : SW_SHOWNOACTIVATE);
        lastHidden = hide;
    }

    // Space reservation for users without a tiling WM (spec 6.1). The appbar
    // owns the strip; komorebi mode reserves through komorebi instead, and
    // the two are mutually exclusive by construction. Returns the rect the
    // shell granted — the caller positions the window to it (never to the
    // un-negotiated frame, which may sit over the taskbar or another appbar).
    RECT negotiateAppBar(const RECT& frame) {
        APPBARDATA data{};
        data.cbSize = sizeof(data);
        data.hWnd = hwnd;
        data.uCallbackMessage = kAppBarCallback;
        if (!appBarRegistered) {
            if (!SHAppBarMessage(ABM_NEW, &data)) return frame;
            appBarRegistered = true;
        }
        // QUERYPOS/SETPOS are cross-process sends to the shell — cache the
        // grant and renegotiate only when the proposal changes (an
        // ABN_POSCHANGED clears the cache to force it).
        if (EqualRect(&frame, &appBarProposed)) return appBarNegotiated;
        data.uEdge = settings.position == BarPosition::Top ? ABE_TOP : ABE_BOTTOM;
        data.rc = frame;
        // The shell may push the proposed rect aside for other appbars; adopt
        // whatever it returns rather than fighting it.
        SHAppBarMessage(ABM_QUERYPOS, &data);
        const LONG height = frame.bottom - frame.top;
        if (data.uEdge == ABE_TOP) data.rc.bottom = data.rc.top + height;
        else data.rc.top = data.rc.bottom - height;
        SHAppBarMessage(ABM_SETPOS, &data);
        appBarProposed = frame;
        appBarNegotiated = data.rc;
        return data.rc;
    }

    // glass / blur_radius (spec 7.6): DWM composes an Acrylic plate behind
    // the window, showing through wherever the scene leaves alpha. The
    // undocumented SetWindowCompositionAttribute accent path is dead on
    // Win11 and is never used.
    void applyBackdrop() {
        // Honour Transparency effects: with it off the shell renders Acrylic
        // as a solid fallback, so a glass bar drops to no backdrop and matches
        // (spec 7.6).
        const bool wantsAcrylic =
            (settings.glass || settings.blurRadius > 0) && systemTransparencyEnabled();
        const auto backdrop =
            static_cast<int>(wantsAcrylic ? DWMSBT_TRANSIENTWINDOW : DWMSBT_NONE);
        DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, sizeof(backdrop));
        // Documented only to darken the frame; that it also selects the dark
        // Acrylic variant is undocumented-but-stable (the same reliance
        // wezterm ships).
        const BOOL dark = TRUE;
        DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, sizeof(dark));
        // A 1px extended frame is what gives a borderless popup the standard
        // drop shadow; zero margins remove it again.
        const MARGINS margins = settings.shadow ? MARGINS{0, 0, 0, 1} : MARGINS{0, 0, 0, 0};
        DwmExtendFrameIntoClientArea(hwnd, &margins);
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
            if (FAILED(CoCreateInstance(kClsidVirtualDesktopManager, nullptr,
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
        // The documented manager can move a window but cannot NAME the
        // current desktop. Explorer records its GUID in the registry — the
        // reliable source, live-verified: the foreground-window trick fails
        // on a freshly created EMPTY desktop, because the only windows there
        // belong to the shell (which is on every desktop), so
        // GetWindowDesktopId cannot answer. The foreground window stays as
        // the fallback for builds where the value is absent.
        GUID current{};
        bool haveCurrent = false;
        HKEY key = nullptr;
        if (RegOpenKeyExW(HKEY_CURRENT_USER,
                          L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer"
                          L"\\VirtualDesktops",
                          0, KEY_READ, &key) == ERROR_SUCCESS) {
            GUID value{};
            DWORD size = sizeof(value);
            DWORD type = 0;
            if (RegQueryValueExW(key, L"CurrentVirtualDesktop", nullptr, &type,
                                 reinterpret_cast<BYTE*>(&value), &size) == ERROR_SUCCESS &&
                type == REG_BINARY && size == sizeof(GUID)) {
                current = value;
                haveCurrent = true;
            }
            RegCloseKey(key);
        }
        if (!haveCurrent) {
            const HWND reference = GetForegroundWindow();
            if (!reference || FAILED(desktopManager->GetWindowDesktopId(reference, &current))) {
                if (!warnedSticky) {
                    warnedSticky = true;
                    std::fprintf(stderr,
                                 "[ybar] sticky=on could not name the current desktop\n");
                }
                return;
            }
        }
        if (FAILED(desktopManager->MoveWindowToDesktop(hwnd, current))) {
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
        appBarProposed = RECT{};
        appBarNegotiated = RECT{};
    }

    // Frame + z + visibility application shared by create/applySettings/DPI
    // change. Everything is guarded on actual change so renderAll's
    // per-frame calls stop re-driving SetWindowPos and shell traffic.
    void applyFrame(const BarSettings& newSettings) {
        settings = newSettings;
        RECT frame = frameFor(settings);
        if (settings.reserve == ybar::model::ReserveMode::AppBar) {
            frame = negotiateAppBar(frame);
        } else {
            removeAppBar();
        }
        const HWND z = zOrder();
        const bool frameChanged = !EqualRect(&frame, &lastAppliedFrame);
        const bool zChanged = z != lastZ;
        if (frameChanged || zChanged) {
            SetWindowPos(hwnd, z, frame.left, frame.top, frame.right - frame.left,
                         frame.bottom - frame.top, SWP_NOACTIVATE);
            lastAppliedFrame = frame;
            lastZ = z;
        }
        if (frameChanged) {
            const int widthPx = frame.right - frame.left;
            const int heightPx = frame.bottom - frame.top;
            surface->resize(widthPx, heightPx);
            logicalW = widthPx / monitorInfo.scale;
            logicalH = heightPx / monitorInfo.scale;
        }
        applyVisibility();
        // No commit step: the composition tree fills the window by relative
        // size, and the swap chain resize above is picked up by its surface.
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
        case WM_TIMECHANGE:
        case WM_THEMECHANGED:
            // Forward broadcasts to the daemon's message-only mailbox, which
            // never receives them directly (spec 5 note). The daemon debounces
            // WM_DISPLAYCHANGE and rebuilds every surface; WM_TIMECHANGE
            // refreshes the clock's zone; WM_THEMECHANGED re-checks
            // transparency.
            if (g_broadcastTarget) PostMessageW(g_broadcastTarget, msg, wParam, lParam);
            return msg == WM_POWERBROADCAST ? TRUE : 0;
        case WM_SETTINGCHANGE:
            // lParam is a string on this message, not a value — forward only
            // the id so the daemon re-reads Transparency effects. (Do not
            // relay the pointer to another window.)
            if (g_broadcastTarget) PostMessageW(g_broadcastTarget, msg, 0, 0);
            return 0;
        case WM_DPICHANGED:
            // PerMonitorV2: adopt the new DPI, recompute the frame from
            // settings (the suggested rect assumes a normal window), and let
            // the daemon swap in the glyph atlas for the new scale.
            if (impl) {
                impl->monitorInfo.scale = static_cast<double>(HIWORD(wParam)) / 96.0;
                // Force a full reapply: even an unchanged physical frame has
                // new logical dimensions at the new scale.
                impl->lastAppliedFrame = RECT{};
                impl->appBarProposed = RECT{};
                impl->applyFrame(impl->settings);
                if (g_broadcastTarget) PostMessageW(g_broadcastTarget, msg, wParam, 0);
            }
            return 0;
        case kAppBarCallback:
            // ABN_* notifications (delivered only because ABM_NEW registered
            // this message id).
            if (impl) {
                if (wParam == ABN_POSCHANGED) {
                    // Taskbar moved/resized or another appbar changed: the
                    // old grant is void — renegotiate and reposition.
                    impl->appBarProposed = RECT{};
                    impl->applyFrame(impl->settings);
                } else if (wParam == ABN_FULLSCREENAPP && g_broadcastTarget) {
                    // Let the daemon re-run its fullscreen elevation pass.
                    PostMessageW(g_broadcastTarget, BarSurface::kFullscreenCheckMessage,
                                 wParam, lParam);
                }
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
            if (impl) {
                // Capture so a slider drag keeps receiving Move/Up after the
                // pointer leaves the (thin) bar — without it, a release
                // outside the window is never seen and the drag wedges.
                SetCapture(hwnd);
                impl->dispatchMouse(MouseEvent::Kind::Down, lParam, "left");
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
            // Capture stolen (menu, system drag) — NOT our own ReleaseCapture:
            // end any drag with a synthetic release so the state machine can
            // never wedge on a press whose release goes elsewhere.
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
                // A stationary pointer can still get WM_MOUSELEAVE here: the
                // bar's z-order and desktop-following upkeep run on the 1 s
                // tick, and a SetWindowPos under the cursor makes Windows
                // re-hit-test and post a leave the pointer never performed.
                // Taken at face value that flaps hover state once a second —
                // an item under a still pointer sees exited/entered pairs
                // forever, which is invisible until something animates on
                // hover, and then it blinks. Confirm against the real cursor
                // before reporting it, the same way a slider release
                // re-verifies containment (spec 6).
                // The test is the window RECT alone, deliberately not
                // WindowFromPoint: the z-order upkeep that provokes these
                // leaves also makes the bar briefly not the top window under
                // the cursor, so asking who owns the point re-admits exactly
                // the spurious leaves this is here to reject.
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

    // Composition tree: target(hwnd) -> [backdrop layer, swap chain]. The
    // target composes in the WINDOW's coordinate space, which is physical
    // pixels for a PerMonitorV2 process, so the physical-pixel buffer maps
    // 1:1 with no transform. (An earlier 96/dpi counter-scale shrank the
    // scene to a quarter of the window on a 200% monitor: full-width window,
    // half-width paint.)
    impl->host = CompositionHost::create(impl->hwnd, impl->surface->compositionSurface());
    if (!impl->host) {
        std::fprintf(stderr, "[ybar] bar composition tree creation failed\n");
        return nullptr;
    }

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
    impl->lastHidden = settings.hidden;
    // The surface already matches `frame`; seed the cache so applyFrame only
    // repositions if appbar negotiation moves us, then let it drive z-order,
    // reservation, and any negotiated move in one place.
    impl->lastAppliedFrame = frame;
    impl->applyFrame(settings);
    impl->applyBackdrop();
    impl->applyStickyPinning();

    std::unique_ptr<BarSurface> bar(new BarSurface());
    bar->impl_ = std::move(impl);
    return bar;
}

BarSurface::~BarSurface() = default;

void BarSurface::applySettings(const BarSettings& settings) {
    const bool stickyChanged = impl_->settings.sticky != settings.sticky;
    const bool backdropChanged = impl_->settings.glass != settings.glass ||
                                 impl_->settings.blurRadius != settings.blurRadius ||
                                 impl_->settings.shadow != settings.shadow;
    impl_->applyFrame(settings); // change-guarded reposition + reservation
    if (backdropChanged) impl_->applyBackdrop();
    if (stickyChanged) impl_->applyStickyPinning();
}

void BarSurface::refreshBackdrop() { impl_->applyBackdrop(); }

void BarSurface::followCurrentDesktop() { impl_->followCurrentDesktop(); }

void BarSurface::setFullscreenElevation(bool elevated) {
    if (impl_->elevatedForFullscreen == elevated) return;
    impl_->elevatedForFullscreen = elevated;
    const HWND z = impl_->zOrder();
    SetWindowPos(impl_->hwnd, z, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    impl_->lastZ = z; // keep applyFrame's change guard honest
}

void BarSurface::setHiddenForFullscreen(bool hidden) {
    if (impl_->hiddenForFullscreen == hidden) return;
    impl_->hiddenForFullscreen = hidden;
    impl_->applyVisibility();
}

bool BarSurface::monitorHasFullscreenWindow() const {
    // Two signals, because neither is sufficient alone:
    //
    //  * SHQueryUserNotificationState says WHETHER the session is running a
    //    genuine full-screen app, but says nothing about which monitor.
    //  * The foreground-rect-covers-the-monitor test says WHERE, but cannot
    //    tell a real full-screen app from an ordinary borderless window that
    //    merely happens to span the display — a maximized borderless editor,
    //    or a game running "Windowed (Fullscreen)". Hiding the bar under
    //    those was user-reported: geometry alone is too eager.
    //
    // Requiring both means the bar yields to an actual full-screen app and
    // stays put for a window that is merely large. QUNS_BUSY covers the
    // generic full-screen case, _RUNNING_D3D_FULL_SCREEN exclusive-mode
    // games, and _PRESENTATION_MODE projector sessions.
    QUERY_USER_NOTIFICATION_STATE notification{};
    if (FAILED(SHQueryUserNotificationState(&notification))) return false;
    if (notification != QUNS_BUSY && notification != QUNS_RUNNING_D3D_FULL_SCREEN &&
        notification != QUNS_PRESENTATION_MODE)
        return false;

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

bool BarSurface::supportsBackdrops() const { return impl_->host->supportsBackdrops(); }

void BarSurface::setBackdrops(const std::vector<ybar::render::Backdrop>& backdrops) {
    impl_->host->setBackdrops(backdrops);
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
