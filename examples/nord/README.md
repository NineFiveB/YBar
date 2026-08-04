# nord

The classic Nord Waybar look for YBar: a flat, fully opaque, full-width
Polar Night strip (height 30, no margin, no corner radius). No pills, no
capsules — every module is plain "icon value" text separated by thin
vertical bars, the way the archetypal Nord Waybar rices style their
`#workspaces`/`#clock`/`#battery` modules.

- **Left** — AeroSpace workspaces as bare numbers (focused = bright white
  on a subtly raised rounded-4 chip, others = muted digits), then the
  frontmost app name in frost blue. Fails soft if AeroSpace is missing.
- **Right** — wifi | volume | battery | clock, with battery colored by
  the Aurora green/yellow/red scale and the clock showing `%a %H:%M`.

Font: JetBrainsMono Nerd Font, Regular, 12 pt (the engine falls back if
it is not installed).

## Credits

Palette: [Nord](https://github.com/nordtheme/nord) by Arctic Ice Studio /
Sven Greb (MIT). Design modeled on the canonical flat Nord
[Waybar](https://github.com/Alexays/Waybar) styling popular in
Hyprland/Sway rices. Structure follows the `examples/darxk` reference
theme and boots through `examples/sketchybar-port`.

## Run

```sh
ybar --config examples/nord/ybarrc.lua
```
