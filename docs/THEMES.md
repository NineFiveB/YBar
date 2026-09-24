# Themes

A YBar theme is a directory with a `ybarrc.lua` (or `ybar.jsonc`,
`ybarrc.jsonc`) entry point. Switch between them with the built-in verbs
(no daemon needed):

```sh
ybar theme list                # shipped + installed themes; * marks the selected one
ybar theme use darxk           # a running bar reloads in place; otherwise YBar.app is started
ybar theme current             # the selected name
ybar theme reset               # forget the selection
ybar theme install <git-url>   # clone a community theme into ~/.config/ybar/themes
```

`use` records the name in `~/.config/ybar/current-theme` and sends the
running daemon `--reload <entry>` — the same verb you can send by hand to
re-point a bar at any config (`ybar --reload ~/x/ybarrc.lua`; a bare
`ybar --reload` re-runs the current one). Config discovery honours the
selection on every later start of the default `ybar` instance, after an
explicit `-c` and before the `~/.config/ybar` search — so drop `-c` from a
LaunchAgent, or let `ybar autostart enable` write one without it
([INSTALL.md](INSTALL.md)). When a selection outranks a config of your own at
the default location, startup says so on stderr and names both files; `ybar
theme reset` hands the bar back to your `~/.config/ybar/ybarrc.lua`. Themes are looked up under `$YBAR_THEME_ROOTS`
(colon-separated), the `examples/` beside the binary, the Homebrew keg's
`share/ybar/examples` and `~/.config/ybar/themes`; from a source checkout,
`scripts/ybar-theme …` forwards to the binary with the checkout's
`examples/` added as a root.

## Shipped themes

| Theme | Directory | Look |
|---|---|---|
| **sketchybar-glass** | `examples/sketchybar-glass` | Liquid Glass: monochrome near-black bar, real `NSGlassEffectView` pills and popups, full widget suite (wifi/bluetooth/battery/calendar/menus/Claude, a system monitor with CPU and memory gauges plus a GPU utilization graph when the driver reports one, and a now-playing popup with album artwork, seek + volume sliders, and transport controls). The flagship. |
| **ysuite** | `examples/ysuite` | Maintainer daily driver — same Liquid Glass suite as `sketchybar-glass`, full-width under `topmost=on` (no island inset) so the native menu bar stays covered edge to edge. |
| **ysuite-liquid** | `examples/ysuite-liquid` | The ysuite-web “Liquid Glass on Metal” mock: full-bleed strip, glass pills, right cluster CPU / Wi-Fi / Bluetooth / battery / clock. |
| **darxk** | `examples/darxk` | Replication of [00Darxk/dotfiles](https://github.com/00Darxk/dotfiles) Waybar: translucent dark bar, segmented rounded capsules with Catppuccin accents, inverted light pills for active workspace and window title, brew-updates + GitHub-notifications modules. |
| **sketchybar-port** | `examples/sketchybar-port` | The full sketchybar-setup port in its original styling. |
| **jsonc-demo** | `examples/jsonc-demo` | Minimal declarative JSONC config — clock and battery, no Lua. |
| **nord** | `examples/nord` | Flat opaque [Nord](https://nordtheme.com) strip: frost icons, aurora battery colors, thin separators, no pills. |
| **gruvbox** | `examples/gruvbox` | Retro powerline: [gruvbox](https://github.com/morhetz/gruvbox) colored segments joined by arrow glyphs. |
| **tokyonight** | `examples/tokyonight` | Floating rounded island in [Tokyo Night](https://github.com/folke/tokyonight.nvim) blues and purples. |
| **dracula** | `examples/dracula` | [Dracula](https://draculatheme.com) colorful blocks — every module its own bright rounded background. |
| **rose-pine** | `examples/rose-pine` | [Rosé Pine](https://rosepinetheme.com) whisper-minimal: workspace dots, lowercase text, zero backgrounds. |

All shipped themes are macOS-tuned: they survive native-fullscreen Spaces
(`fullscreen_show`), auto-detect the notch (`notch_width = 0`, centered
content uses the `q`/`e` cursors so it flanks the housing), show charging
state, and their modules are interactive — scroll the volume module to
adjust it (through `ybar.volume`, an in-process CoreAudio write; the themes
no longer spawn `osascript` for it), click volume/battery/wifi for the
matching Settings pane, click the clock for Calendar (`helpers/mac.lua` has
the shared pieces).

To hide the native macOS menu bar, set `topmost = "on"` on the bar (the
Liquid Glass themes do). With menu-bar auto-hide enabled, macOS still
reveals its bar when the pointer hits the top edge; at status-bar level
YBar draws over it - no private APIs or SIP changes required. The cover is
only the panel's own rect, though: the engine paints nothing outside it, so
the native bar stays visible wherever the panel is inset. The
`sketchybar-glass` island (`margin = 10`, `y_offset = 6`, `corner_radius =
9`) leaves it showing in the top band, the side columns and the corner
cutouts - and the auto-hide reveal lands exactly in that band - while
`ysuite` keeps `margin = 0` / `y_offset = 0` so the cover runs edge to
edge along the top and both sides; it keeps `corner_radius = 9`, so only
the four corner cutouts remain (the top pair sit in the screen's own
corners).
The native status items become unclickable while covered, which is why
the themes ship replacements for them.

## Writing a theme

Start from `examples/darxk` — it is the smallest complete Lua theme
(~300 lines): bar + defaults, capsule brackets, event-driven modules. The
sketchybar compat shim (`sbar = require("sketchybar")`) or the native
`ybar.*` API both work. Fail soft: probe for optional binaries
(`aerospace`, `brew`, `gh`) and hide modules when they are absent, so one
theme works across machines.

A few engine idioms the shipped themes lean on:

- `slider.interactive = "off"` turns a slider into a read-only fill meter
  (a battery or CPU pill): a press is an ordinary click and never scrubs the
  value, while `slider.percentage` sets still apply.
- `icon.background.*` / `label.background.*` draw a plate behind that part
  alone, at ink width plus the part's own paddings, without widening the item
  — a badge, or one highlighted label inside a pill.
- `background.shadow.blur` with a light `background.shadow.color` at
  distance 0 is a glow; on a translucent pill the halo also tints the
  interior, so tune the fill alpha together with it.
- `helpers/hover.lua` (in `sketchybar-port`, shared by the glass theme) is
  the hover-feedback helper: `hover.pill(bracket, member)` lifts a pill's
  fill while the pointer is over it, `hover.row(item)` lights a popup row
  from transparent.

## Sharing a theme

Publish the theme directory as a git repo, then anyone can:

```sh
ybar theme install https://github.com/you/my-ybar-theme
```

To be listed here, add a row to this table (and an entry to
`themes/registry.json`) in a PR. Tag the repo with the `ybar-theme` GitHub
topic so it is discoverable.
