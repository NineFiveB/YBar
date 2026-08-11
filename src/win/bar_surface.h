// Per-monitor bar window (spec section 6): borderless non-activating
// WS_EX_NOREDIRECTIONBITMAP popup with a DirectComposition visual hosting the
// renderer's composition swap chain.

#pragma once

#include <memory>

#include "model/bar_settings.h"
#include "render/renderer.h"
#include "win/display_manager.h"

namespace ybar::win {

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
