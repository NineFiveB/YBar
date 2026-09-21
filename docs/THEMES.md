# Themes

A YBar theme is a directory with a `ybarrc.lua` (or `ybar.jsonc`) entry point.
Switch between them with the selector:

```sh
scripts/ybar-theme list           # shipped + installed themes
scripts/ybar-theme use darxk      # relaunch the bar with a theme
scripts/ybar-theme install <git-url>   # add a community theme
scripts/ybar-theme reset          # forget the recorded theme
```

`use` records the choice in `~/.config/ybar/current-theme`, and config
discovery reads that file whenever no `-c` was given — so a bar started by
`ybar start`, or by the login agent `ybar autostart enable` installs, comes up
in the theme you last selected. That resolution covers themes installed under
`~/.config/ybar/themes` and the ones Homebrew ships under
`share/ybar/examples`; a theme run straight out of a git clone is not on that
search path, so from a clone keep passing `-c examples/<name>/ybarrc.lua`.
A theme off that search path still applies for the session — `use` passes it
explicitly and tells you it will not survive a logout. Deleting a theme is safe
either way: a name that no longer resolves falls through to
`~/.config/ybar/ybarrc.lua`, and `ybar-theme reset` forgets the recorded name
outright. One exception: a login job created with `ybar autostart enable -c
<path>` pins that config and ignores the recorded theme, so `use` refuses
rather than reporting a switch that will not happen.

## Shipped themes

| Theme | Directory | Look |
|---|---|---|
| **sketchybar-glass** | `examples/sketchybar-glass` | Liquid Glass: monochrome near-black bar, real `NSGlassEffectView` pills and popups, full widget suite (wifi/bluetooth/battery/system monitor/calendar/menus/Claude, and a now-playing popup with album artwork, seek + volume sliders, and transport controls). The flagship. |
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
adjust it, click volume/battery/wifi for the matching Settings pane, click
the clock for Calendar (`helpers/mac.lua` has the shared pieces).

To hide the native macOS menu bar entirely, set `topmost = "on"` on the bar
(the glass theme does). With menu-bar auto-hide enabled, macOS still reveals
its bar when the pointer hits the top edge; at status-bar level YBar covers
it, so it is never visible - no private APIs or SIP changes required. The
native status items become unclickable while covered, which is why the
themes ship replacements for them.

## Writing a theme

Start from `examples/darxk` — a complete Lua theme in under 400 lines:
bar + defaults, capsule brackets, event-driven modules. The
sketchybar compat shim (`sbar = require("sketchybar")`) or the native
`ybar.*` API both work. Fail soft: probe for optional binaries
(`aerospace`, `brew`, `gh`) and hide modules when they are absent, so one
theme works across machines.

## Sharing a theme

Publish the theme directory as a git repo, then anyone can:

```sh
scripts/ybar-theme install https://github.com/you/my-ybar-theme
```

To be listed here, add a row to this table (and an entry to
`themes/registry.json`) in a PR. Tag the repo with the `ybar-theme` GitHub
topic so it is discoverable.
