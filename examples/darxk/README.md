# darxk

A YBar replication of the Waybar setup from
[00Darxk/dotfiles](https://github.com/00Darxk/dotfiles): a translucent dark
bar of segmented rounded capsules with per-module Catppuccin accents,
inverted light pills for the active workspace and the window title, and bold
monospace type.

It is also the **reference theme for writing your own** — the smallest
complete Lua theme in the tree (~300 lines): bar and defaults, capsule
brackets, event-driven modules, nothing else. Start here rather than in the
flagship.

- **Left** — clock, wifi, bluetooth in one capsule; then the focused window
  title as a light pill.
- **Center** — AeroSpace workspaces as small rounded buttons, the focused
  one inverted; lock button; `brew outdated` and GitHub notification counts.
- **Right** — media, thermal, battery, volume.

## Helpers and permissions

None. Every module reads the engine's own providers or a standard CLI
(`brew`, `gh`), and each probes for its binary and hides itself when absent
— so this theme works from a bare `brew install` with no build step and no
permission prompts beyond YBar's own.

It borrows the compat shim from `../sketchybar-port` (resolved beside this
directory, or from `~/.config/ybar/themes/` when installed), so that tree
must be present.

Font: JetBrainsMono Nerd Font (the engine falls back if it is not
installed).

## Credits

Design: [00Darxk/dotfiles](https://github.com/00Darxk/dotfiles). Palette:
[Catppuccin](https://github.com/catppuccin/catppuccin).

## Run

```sh
ybar --config examples/darxk/ybarrc.lua
```
