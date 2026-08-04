# gruvbox

A retro powerline theme for YBar. Modules are solid full-height colored
blocks with dark bold text, chained with powerline arrow separators
(`U+E0B2`) so each segment flows into the next — the classic
vim-airline / tmux-powerline statusline look, on your menu bar.

- **Left** — AeroSpace workspaces as blocks (focused = yellow with dark
  text, others = gray with light text), then the focused app in plain text.
- **Right** (left to right) — wifi (gray) > volume (orange) > battery
  (aqua) > clock (yellow), each block growing out of the previous one via
  an arrow separator.

Opaque `0xff282828` bar, height 30, zero margin, zero corner radius.
Font: JetBrainsMono Nerd Font Bold 12 (the engine falls back gracefully
if it is not installed; the arrow glyphs need a Nerd Font / Powerline
patched font).

Fails soft: without the `aerospace` CLI the workspace blocks simply do
not appear.

## Credits

- Palette: [gruvbox](https://github.com/morhetz/gruvbox) by Pavel Pertsev
  — retro groove colors (dark0 `#282828`, light1 `#ebdbb2`, yellow
  `#d79921`, aqua `#689d6a`, orange `#d65d0e`, red `#cc241d`, dark2
  `#504945`).
- Separator glyphs: the [Powerline](https://github.com/powerline/powerline)
  project, shipped in [Nerd Fonts](https://www.nerdfonts.com/).
- Structure follows the `examples/darxk` reference theme and the
  `examples/sketchybar-port` compat shim.

## Run

Point YBar at this directory's `ybarrc.lua` (it bootstraps the
sketchybar compat shim from `../sketchybar-port`).
