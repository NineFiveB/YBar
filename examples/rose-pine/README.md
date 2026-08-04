# rose-pine

An airy, quiet YBar theme. Ultra-minimal text on a translucent Rosé Pine
base — no capsules, no pills, no backgrounds. Everything whispers.

Palette and mood come from [Rosé Pine](https://rosepinetheme.com)
("all natural pine, faux fur and a bit of soho vibes"), main variant.

## Layout

- **Left** — AeroSpace workspaces as dots: a filled foam circle for the
  focused workspace, small muted outline circles for the rest (clickable);
  then the frontmost app name in lowercase iris.
- **Right** — wifi (iris glyph only), volume (rose glyph + muted percent),
  battery (foam glyph + muted percent), clock (gold `%H:%M`).

Bar: height 32, `0xE6191724`, zero margin. Type: SF Pro Regular 12 with
wide, even spacing.

## Notes

- Workspaces need [AeroSpace](https://github.com/nikitabobko/AeroSpace);
  without it the dots simply never appear — nothing errors.
- Uses the `examples/sketchybar-port` compat shim; run with
  `ybar --config examples/rose-pine/ybarrc.lua` (or symlink as your
  `~/.config/ybar/ybarrc.lua`).
