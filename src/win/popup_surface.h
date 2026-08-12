// Anchored popup panel (spec 3.9, 6): topmost non-activating composition
// window above its bar, sized to the popup scene, aligned l/c/r to the host
// frame and hung below a top bar / above a bottom bar.

#pragma once

#include <functional>
#include <memory>

#include "model/bar_settings.h"
#include "model/geometry.h"
#include "render/renderer.h"
#include "win/bar_surface.h"

namespace ybar::win {

class PopupSurfaceImpl;

class PopupSurface {
public:
    static std::unique_ptr<PopupSurface> create(ybar::render::Renderer& renderer, double scale);
    ~PopupSurface();

    // Anchor = host frame in SCREEN physical pixels; sizes in logical points.
    // align 'c'/'r'/other-left; below=true for top bars.
    void present(ybar::model::Size panelSize, const ybar::model::Rect& anchorScreenPx,
                 char align, bool below, double yOffset);
    void hide();

    ybar::render::Surface& renderSurface();
    double scale() const;
    void setMouseHandler(std::function<void(const MouseEvent&)> handler);
    void* hwnd() const;

private:
    PopupSurface() = default;
    std::unique_ptr<PopupSurfaceImpl> impl_;
};

} // namespace ybar::win
