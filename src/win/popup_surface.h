// Anchored popup panel (spec 3.9, 6): topmost non-activating composition
// window above its bar, sized to the popup scene, aligned l/c/r to the host
// frame and hung below a top bar / above a bottom bar. Same composition tree
// as the bar (Windows.UI.Composition, spec 7.6): swap chain over a backdrop
// layer that can carry a Mica material under the panel and under glass rows.

#pragma once

#include <functional>
#include <memory>
#include <vector>

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
    // fadeInFrames applies on the hidden->shown edge only (see fadeIn).
    void present(ybar::model::Size panelSize, const ybar::model::Rect& anchorScreenPx,
                 char align, bool below, double yOffset, double fadeInFrames = 0);
    void hide();

    // Opacity fades run on the COMPOSITOR, not the app: the animation is
    // handed to the compositor once and this process renders no frames
    // while it plays. `frames` is at 60Hz; 0 snaps.
    //
    // present() calls fadeIn on the hidden->shown edge ONLY. Re-issuing the
    // animation every frame would restart it and the panel would never
    // finish appearing.
    void fadeIn(double frames);
    // Starts the fade and returns at once. The caller keeps the surface alive
    // for the duration, then calls hide().
    void fadeOut(double frames);

    // DWM Acrylic plate (the fallback material when the Mica layer is
    // unavailable) + rounded backdrop corners (spec 7.6). Cheap and
    // idempotent; call whenever the popup's blur/corner settings may differ.
    void setBackdrop(bool acrylic, double cornerRadius);

    // Mica layer (spec 7.6): whether this system composes wallpaper-material
    // visuals, the same answer before any surface exists (a popup's scene is
    // built first), and the per-present sync of that layer to the scene's
    // DisplayList::backdrops (panel-local device px).
    bool supportsBackdrops() const;
    static bool backdropsAvailable();
    void setBackdrops(const std::vector<ybar::render::Backdrop>& backdrops);

    ybar::render::Surface& renderSurface();
    double scale() const;
    void setMouseHandler(std::function<void(const MouseEvent&)> handler);
    void* hwnd() const;

private:
    PopupSurface() = default;
    std::unique_ptr<PopupSurfaceImpl> impl_;
};

} // namespace ybar::win
