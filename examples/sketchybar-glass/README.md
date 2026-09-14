# sketchybar-glass

The flagship theme: the full `examples/sketchybar-port` setup restyled as
dark **Liquid Glass** — real `NSGlassEffectView` backdrops on macOS 26+
(clear for bar pills, frosted for popups), a monochrome near-black palette,
and 20 pt corners.

Every item file comes from `../sketchybar-port` unchanged. This directory
holds only `colors.lua`, `bar.lua`, `default.lua` and the entry point, so
widget fixes land once and both themes get them.

The palette is deliberately achromatic — states read through brightness and
glyph shape, not hue — with one exception: `colors.connected`, the green on
the Wi-Fi and VPN "Connected" rows.

## Helpers and permissions

Identical to the port it layers on, including the two opt-in `make helpers`
builds for the app-menu swap and menu-bar extras widget: see
[`../sketchybar-port/README.md`](../sketchybar-port/README.md). Everything
else works from a `brew install` with no build step.

## Layering

`ybarrc.lua` resolves the port tree beside this directory, falling back to
`~/.config/ybar/themes/sketchybar-port` when the theme was installed
through `ybar theme install`. Both trees must be present.

## Run

```sh
ybar --config examples/sketchybar-glass/ybarrc.lua
# or, once installed:
ybar theme use sketchybar-glass
```
