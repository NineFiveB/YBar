# darxk

A YBar replication of the Waybar setup from
[00Darxk/dotfiles](https://github.com/00Darxk/dotfiles): a translucent dark
bar of segmented rounded capsules with per-module Catppuccin accents, inverted
light pills for the active workspace and the focused window, and bold
monospace type throughout.

It is also the **reference theme for writing your own** — the smallest
complete Lua theme in the tree (~300–400 lines): bar and defaults, capsule
brackets, event-driven modules, nothing else.
[THEMES.md](../../docs/THEMES.md) points theme authors at it first.

It uses the `sketchybar` compat shim, so **`../sketchybar-port` must be
installed beside it** — `ybarrc.lua` probes for it and falls back to
`~/.config/ybar/themes/sketchybar-port`.

## Layout

- **Left** — clock, network and bluetooth share one segmented capsule (a
  bracket supplies the capsule; each module colors its own contents), then
  the focused window title as an inverted light pill.
- **Center** — AeroSpace workspaces inside a dark outer capsule, the focused
  one inverted and wider, shown only when non-empty or focused; then a
  power/lock capsule, then the `updates` and `github` modules.
- **Right**, in Waybar's order — now-playing media (marquee via
  `scroll_texts`, Spotify green when Spotify is the source, click to
  play/pause), a hardware capsule pairing thermal state with battery, and a
  volume capsule.

## Helpers and permissions

None beyond YBar's own. Every module that shells out hides itself rather than
erroring when its binary is missing, so one config works across machines:

- **Workspaces** need [AeroSpace](https://github.com/nikitabobko/AeroSpace).
  It is probed at `/opt/homebrew/bin`, then `/usr/local/bin`, then `PATH`;
  with none of them the workspace items are simply never added.
- **`updates`** counts `brew outdated` and draws only when the count is above
  zero, so no Homebrew means no module at all. Amber below ten outdated
  formulae, red at ten and above.
- **`github`** counts unread notifications through `gh api notifications` and
  draws only when the call succeeds and the count is above zero, so an
  unauthenticated or absent `gh`, or an empty inbox, leaves nothing behind.

Font: JetBrainsMono Nerd Font, Bold (the engine falls back if it is not
installed).

## Credits

Design, layout and palette are a replication of the Waybar configuration in
[00Darxk/dotfiles](https://github.com/00Darxk/dotfiles); the colors in
`colors.lua` are read from its `waybar/style.css` and are Catppuccin-flavored.
This is a re-implementation on YBar's item model, not a port of its CSS. The
credit is also recorded in the repository's
[THIRD_PARTY.md](../../THIRD_PARTY.md).

## Run

```sh
ybar -c examples/darxk/ybarrc.lua
# or: ybar --config examples/darxk/ybarrc.lua
```
