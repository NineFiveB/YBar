// Per-monitor bar window (spec section 6): borderless non-activating
// WS_EX_NOREDIRECTIONBITMAP popup with a Windows.UI.Composition tree hosting
// the renderer's composition swap chain over the per-pill backdrop layer.

#pragma once

#include <functional>
#include <memory>
#include <vector>

#include "model/bar_settings.h"
#include "render/renderer.h"
#include "win/display_manager.h"

namespace ybar::win {

// Bar-local mouse event in LOGICAL points (spec sections 3.5, 6).
struct MouseEvent {
    enum class Kind { Down, Up, Move, Leave, Scroll };
    Kind kind = Kind::Move;
    double x = 0;
    double y = 0;
    const char* button = "left";    // left | right | other
    const char* modifier = "none";  // shift | ctrl | alt | cmd | none
    int scrollDelta = 0;
};

class BarSurfaceImpl;

class BarSurface {
public:
    // Posted to the broadcast target when the shell announces
    // ABN_FULLSCREENAPP — the daemon re-runs its fullscreen elevation pass.
    // (0x8000 == WM_APP; windows.h is deliberately not included here.)
    static constexpr unsigned kFullscreenCheckMessage = 0x8000 + 32;

    // Creates the window + composition tree and shows it without activation.
    static std::unique_ptr<BarSurface> create(ybar::render::Renderer& renderer,
                                              const MonitorInfo& monitor,
                                              const ybar::model::BarSettings& settings);
    ~BarSurface();

    // Re-applies frame/level from settings (height/margin/topmost/hidden...).
    void applySettings(const ybar::model::BarSettings& settings);

    // Re-applies the DWM backdrop (glass/blur vs the system Transparency
    // effects setting) without a settings change — driven from WM_SETTINGCHANGE.
    void refreshBackdrop();

    // fullscreen_show: raise this surface over a fullscreen window on ITS
    // monitor, or drop it back to the configured level (spec 6).
    void setFullscreenElevation(bool elevated);
    // fullscreen_show=off (default): auto-hide this surface while a fullscreen
    // window covers its monitor, and show it again otherwise. ORed with the
    // user's hidden= toggle.
    void setHiddenForFullscreen(bool hidden);
    bool monitorHasFullscreenWindow() const;

    // sticky=on upkeep: follow the active virtual desktop. Driven from the
    // daemon's 1 s tick because desktop switches raise no window message.
    void followCurrentDesktop();

    // Mouse events arrive on the UI thread (the window's own WndProc).
    void setMouseHandler(std::function<void(const MouseEvent&)> handler);

    // Broadcast messages (WM_POWERBROADCAST suspend/resume, WM_FONTCHANGE)
    // never reach message-only windows — the bar windows forward them here.
    static void setBroadcastTarget(void* messageWindow);

    // Per-pill backdrops (spec 7.6): whether this system can compose a
    // wallpaper-material visual under a glass pill, and the per-frame sync
    // of that layer to the scene's DisplayList::backdrops (device px).
    bool supportsBackdrops() const;
    void setBackdrops(const std::vector<ybar::render::Backdrop>& backdrops);

    ybar::render::Surface& renderSurface();
    const MonitorInfo& monitor() const;
    double scale() const;
    void* hwnd() const;
    // Window origin in screen physical pixels (popup anchoring).
    ybar::model::Point screenOrigin() const;
    // Bar content size in logical points (frame minus nothing; margins are
    // outside the window).
    double logicalWidth() const;
    double logicalHeight() const;

private:
    BarSurface() = default;
    std::unique_ptr<BarSurfaceImpl> impl_;
};

} // namespace ybar::win
