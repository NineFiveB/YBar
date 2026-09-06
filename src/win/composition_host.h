// Windows.UI.Composition host for a bar or popup window (spec sections 6,
// 7.1, 7.6): the renderer's composition swap chain as the top visual, over a
// layer of wallpaper-backdrop ("Mica") visuals — one per glass pill on a bar,
// one for the whole panel on a popup — and the root opacity a popup fades.

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
    // The same answer without a host: a popup's scene is built before its
    // surface exists. Creates the thread's compositor on first use.
    static bool backdropsAvailable();

    // Syncs the backdrop layer to this frame's glass pills, window-local
    // device px. Change-guarded: an identical list is a no-op, so the
    // per-frame call costs nothing while the bar is static.
    void setBackdrops(const std::vector<ybar::render::Backdrop>& backdrops);

    // Whole-tree opacity ramp on the compositor: `from` -> `to` over
    // `seconds`, linear, holding `to` afterwards; seconds <= 0 snaps. The
    // process renders no frames while it plays (popup open/close fades).
    void rampOpacity(float from, float to, double seconds);

private:
    CompositionHost() = default;
    std::unique_ptr<CompositionHostImpl> impl_;
};

} // namespace ybar::win
