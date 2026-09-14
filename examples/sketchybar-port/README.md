# sketchybar-port

The full [sketchybar-setup](https://github.com/FelixKratz/dotfiles) port, in
its original styling: Apple menu, app-menu swap, workspace pills with live
app icons, calendar, and the widget suite (wifi, bluetooth, battery, system
monitor, media, Claude Code sessions).

This is the tree the other flagship themes layer on top of.
`examples/sketchybar-glass` reuses every item file here verbatim and only
replaces `colors.lua` / `bar.lua` / `default.lua`, so a fix here reaches
both. `PORTING.md` records what changed against the sketchybar original and
why.

## Helpers

Most widgets are pure Lua over the engine's own providers. Six shell out to
a helper in `helpers/`, and two of those are **opt-in builds** that no
install ships:

| Helper | Used by | Ships with |
|---|---|---|
| `menus/bin/menus` | app-menu swap, Apple menu right-click | **`make helpers` only** |
| `bin/statusitems` | menu-bar extras widget (`widgets/menubar.lua`) | **`make helpers` only** |
| `calendar_events.swift` | calendar popup event rows | compiled on first use |
| `battery_history.py`, `wifi_scan.py`, `bluetooth_battery.sh`, `system_stats_rich.sh`, `claude_agents.sh` | battery / wifi / bluetooth / cpu / Claude widgets | as-is, no build |

```sh
make helpers    # from a clone: builds menus + statusitems into helpers/
```

`menus` links the private **SkyLight** framework. That is why it is opt-in
and why the Homebrew formula never builds it — YBar's own engine is
[100% public APIs](../../README.md), and that promise would not survive
bundling this. Without it the theme simply creates no menu items and the
swap becomes a no-op, so a `brew install` gets a clean bar rather than
items that fail silently. `statusitems` is public-API (Accessibility) but
is built the same way, since it has no use outside this theme.

The lookup path is `SKETCHYBAR_CONFIG` — set by `ybarrc.lua` to this
directory, so a theme layered on top still finds the helpers here.

## Permissions

Beyond YBar's own first-run grants (see
[docs/INSTALL.md](../../docs/INSTALL.md)):

- **Accessibility** — app-menu swap, Apple menu, menu-bar extras widget.
- **Automation (Music/Spotify)** — the media widget's now-playing popup,
  requested the first time a player is running and the widget subscribes.
- **Calendar** — the calendar popup's event rows; without it the grid
  still renders and the event list stays empty.
- **Bluetooth** — device battery levels in the bluetooth popup.

## Run

```sh
ybar --config examples/sketchybar-port/ybarrc.lua
```
