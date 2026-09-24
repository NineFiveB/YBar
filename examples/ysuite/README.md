# ysuite

Maintainer daily driver — the Liquid Glass setup that runs on the YBar
development Mac ([NineFiveB/YBar](https://github.com/NineFiveB/YBar)).

## Look

- Monochrome near-black Liquid Glass strip (`NSGlassEffectView` on macOS 26+)
- Full-width bar at status-bar level (`topmost=on`) covering the native menu bar
- Full widget suite from `../sketchybar-port`: AeroSpace workspaces with live
  app icons, app-menus swap, calendar, battery + 24h history, bluetooth,
  wifi (SSID via CoreWLAN / Location), CPU + memory gauges, now-playing

## vs `sketchybar-glass`

Same colors, fonts, defaults and item files — this directory holds only
`bar.lua` and the entry point, and resolves the rest from
`../sketchybar-glass` and `../sketchybar-port`. This setup keeps `margin=0` /
`y_offset=0` so the panel fully covers the menu-bar strip. `sketchybar-glass`
experiments with a floating island inset; without an engine-side full-bleed
cover that leaks the native menu bar at the gaps.

## Use

```sh
# from a source checkout
scripts/ybar-theme use ysuite

# or once installed
ybar theme use ysuite
```

Requires the `sketchybar-glass` and `sketchybar-port` trees beside this
theme (shipped in `examples/`; `ybarrc.lua` falls back to
`~/.config/ybar/themes` for both). Optional: `ybar --bar wifi_ssid_prompt=on`
once for the Wi-Fi network name (Location Services).
