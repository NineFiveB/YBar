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
5. **Media widget** — ported on YBar's `media_change` event (Music/Spotify
   distributed notifications; no MediaRemote): `items/widgets/media.lua`,
   marquee title, click toggles play/pause.

## Helper binaries

Two helpers are compiled, not vendored as binaries: run `make helpers` from
the repo root once (builds `helpers/bin/statusitems` for the Background
widget and `helpers/menus/bin/menus` for the app-menus row). The calendar
events helper self-compiles on first run.

## AeroSpace hook

The spaces widget listens for `aerospace_workspace_change`. Update
`~/.aerospace.toml` to notify ybar (keep the sketchybar line too if you run
both):

```toml
exec-on-workspace-change = ['/opt/homebrew/bin/ybar', '--trigger', 'aerospace_workspace_change']
# (the ybar CLI folds $AEROSPACE_* from its environment into the trigger)
```

## Known behavioral differences

- Popups auto-close on outside clicks by default (YBar extension); add
  `popup = { auto_close = false }` to a host for sketchybar's script-only
  lifecycle. The config's own `mouse.exited.global` close handlers also work.
- `background.image` (`app.<Name>` icons, files), `scroll_texts` marquee,
  and per-item `blur_radius` are implemented engine features now, not
  ignored compat stubs.
- Fonts: SF Pro / SF Mono / sketchybar-app-font resolve through CoreText by
  family name — install them as before (`brew install --cask font-sketchybar-app-font`).
