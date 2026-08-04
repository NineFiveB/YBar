# dracula

Colorful-blocks theme for YBar: every module gets its own bright rounded
block (radius 8, height 24) with dark text, on a slightly translucent
Dracula-dark bar.

Palette and design origin: the [Dracula theme](https://draculatheme.com)
color specification by Zeno Rocha and contributors (MIT).

Layout

- Left: AeroSpace workspaces (focused = pink block with dark text,
  inactive = current-line grey with light text; hidden without the
  `aerospace` CLI), then the frontmost app in a purple block.
- Right: Wi-Fi (cyan), volume (green), battery (orange, turning red at
  15% or below), clock (purple, rightmost).

Font: JetBrainsMono Nerd Font Bold 12 (the engine falls back gracefully
if it is not installed). Icons are Material Design glyphs from the Nerd
Font PUA range.

Run: point YBar at `examples/dracula/ybarrc.lua`. Uses the sketchybar
compat shim from `../sketchybar-port`.
