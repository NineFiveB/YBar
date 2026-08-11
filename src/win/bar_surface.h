// Per-monitor bar window (spec section 6): borderless non-activating
// WS_EX_NOREDIRECTIONBITMAP popup with a DirectComposition visual hosting the
// renderer's composition swap chain.

#pragma once

#include <functional>
#include <memory>

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
    // Creates the window + composition tree and shows it without activation.
    static std::unique_ptr<BarSurface> create(ybar::render::Renderer& renderer,
                                              const MonitorInfo& monitor,
                                              const ybar::model::BarSettings& settings);
    ~BarSurface();

    // Re-applies frame/level from settings (height/margin/topmost/hidden...).
    void applySettings(const ybar::model::BarSettings& settings);

    // Mouse events arrive on the UI thread (the window's own WndProc).
    void setMouseHandler(std::function<void(const MouseEvent&)> handler);

    // Broadcast messages (WM_POWERBROADCAST suspend/resume, WM_FONTCHANGE)
    // never reach message-only windows — the bar windows forward them here.
    static void setBroadcastTarget(void* messageWindow);

    ybar::render::Surface& renderSurface();
    const MonitorInfo& monitor() const;
    double scale() const;
    // Bar content size in logical points (frame minus nothing; margins are
    // outside the window).
    double logicalWidth() const;
    double logicalHeight() const;

private:
    BarSurface() = default;
    std::unique_ptr<BarSurfaceImpl> impl_;
};

} // namespace ybar::win
