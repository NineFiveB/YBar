# Themes

A YBar theme is a directory with a `ybarrc.lua` (or `ybar.jsonc`) entry point.
Switch between them with the selector:

```sh
scripts/ybar-theme list           # shipped + installed themes
scripts/ybar-theme use darxk      # relaunch the bar with a theme
scripts/ybar-theme install <git-url>   # add a community theme
```

## Shipped themes

| Theme | Directory | Look |
|---|---|---|
| **sketchybar-glass** | `examples/sketchybar-glass` | Liquid Glass: monochrome near-black bar, real `NSGlassEffectView` pills and popups, full widget suite (wifi/bluetooth/battery/system monitor/calendar/menus/media/Claude). The flagship. |
| **darxk** | `examples/darxk` | Replication of [00Darxk/dotfiles](https://github.com/00Darxk/dotfiles) Waybar: translucent dark bar, segmented rounded capsules with Catppuccin accents, inverted light pills for active workspace and window title, brew-updates + GitHub-notifications modules. |
| **sketchybar-port** | `examples/sketchybar-port` | The full sketchybar-setup port in its original styling. |
| **jsonc-demo** | `examples/jsonc-demo` | Minimal declarative JSONC config — clock and battery, no Lua. |
| **nord** | `examples/nord` | Flat opaque [Nord](https://nordtheme.com) strip: frost icons, aurora battery colors, thin separators, no pills. |
| **gruvbox** | `examples/gruvbox` | Retro powerline: [gruvbox](https://github.com/morhetz/gruvbox) colored segments joined by arrow glyphs. |
| **tokyonight** | `examples/tokyonight` | Floating rounded island in [Tokyo Night](https://github.com/folke/tokyonight.nvim) blues and purples. |
| **dracula** | `examples/dracula` | [Dracula](https://draculatheme.com) colorful blocks — every module its own bright rounded background. |
| **rose-pine** | `examples/rose-pine` | [Rosé Pine](https://rosepinetheme.com) whisper-minimal: workspace dots, lowercase text, zero backgrounds. |

## Writing a theme

Start from `examples/darxk` — it is the smallest complete Lua theme
(~300 lines): bar + defaults, capsule brackets, event-driven modules. The
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
