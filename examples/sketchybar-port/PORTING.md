# Porting notes — ShishaKnight/SketchyBar-Setup on YbarLua

The original SbarLua config (~2,900 lines) runs on YBar through the
`sketchybar.lua` compat shim with **verbatim copies** of: `colors.lua`,
`settings.lua`, `icons.lua`, `bar.lua`, `default.lua`, `front_app.lua`,
`spaces.lua`, `battery.lua`, and `helpers/{default_font,shell,app_icons}.lua`.

## Install

```sh
mkdir -p ~/.config/ybar
cp -R examples/sketchybar-port/* ~/.config/ybar/
ybar          # or restart the daemon
```

## Deltas from the original (all marked `YBAR PORT` in-source)

1. **Entry point** — `ybarrc.lua` replaces `sketchybarrc` + `init.lua`;
   `sbar = require("sketchybar")` loads the compat shim instead of the SbarLua
   `.so`. No helper `make` at startup.
2. **Helper binaries stay in the original tree** — `SKETCHYBAR_CONFIG` at the
   top of `ybarrc.lua` points at your sketchybar checkout for: `menus` (menu-bar
   capture), `calendar_events.sh`, `bluetooth_battery.sh`, `system_stats.sh`,
   `altserver_click.sh`. Adjust if yours lives elsewhere.
3. **CPU provider** — the `cpu_load` event-provider binary is replaced by
   YBar's built-in `system_stats` event (in-process kernel sampling;
   `env.CPU_USAGE` instead of `env.total_load`). The popup's RAM/GPU/disk
   sliders still use `system_stats.sh`.
4. **Network speeds** — the `network_load` binary is optional as before; the
   port registers the `network_update` event up front so subscriptions succeed
   without it (speeds show `??? Bps` until the binary exists).
5. **Media widget not ported** — it needs the `media_change` event
   (MediaRemote, entitlement-locked since macOS 15.3). Planned on top of
   YBar's platform-binary now-playing adapter.

## AeroSpace hook

The spaces widget listens for `aerospace_workspace_change`. Update
`~/.aerospace.toml` to notify ybar (keep the sketchybar line too if you run
both):

```toml
exec-on-workspace-change = ['/bin/bash', '-c',
  'ybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE=$AEROSPACE_FOCUSED_WORKSPACE'
]
```

## Known behavioral differences

- Popups auto-close on outside clicks by default (YBar extension); add
  `popup = { auto_close = false }` to a host for sketchybar's script-only
  lifecycle. The config's own `mouse.exited.global` close handlers also work.
- `background.image` (media artwork, `app.<Name>` icons), `scroll_texts`
  marquee, and per-item `blur_radius` are accepted-and-ignored.
- Fonts: SF Pro / SF Mono / sketchybar-app-font resolve through CoreText by
  family name — install them as before (`brew install --cask font-sketchybar-app-font`).
