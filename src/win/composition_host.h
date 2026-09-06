// Windows.UI.Composition host for a bar window (spec sections 6, 7.1, 7.6):
// the renderer's composition swap chain as the top visual, over a layer of
// wallpaper-backdrop ("Mica") visuals clipped to each glass pill.

#pragma once

#include <memory>
#include <vector>

#include "render/instances.h"

namespace ybar::win {

class CompositionHostImpl;

class CompositionHost {
public:
    // Attaches a composition target to `hwnd` (HWND) and hosts `swapChain`
    // (IDXGISwapChain1*) as the content visual. Null on failure. Must be
    // called on the UI thread; the first call also creates that thread's
    // dispatcher queue and compositor, which then live for the process.
    static std::unique_ptr<CompositionHost> create(void* hwnd, void* swapChain);
    ~CompositionHost();

    // True when the wallpaper backdrop brush exists on this system (the
    // Windows 11 compositor). False = the layer is inert and the scene
    // builder should not cut the bar background under glass pills.
    bool supportsBackdrops() const;

    // Syncs the backdrop layer to this frame's glass pills, window-local
    // device px. Change-guarded: an identical list is a no-op, so the
    // per-frame call costs nothing while the bar is static.
    void setBackdrops(const std::vector<ybar::render::Backdrop>& backdrops);

private:
    CompositionHost() = default;
    std::unique_ptr<CompositionHostImpl> impl_;
};

} // namespace ybar::win
