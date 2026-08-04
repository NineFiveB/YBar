# tokyonight — the floating island bar

A YBar theme in the [Tokyo Night](https://github.com/folke/tokyonight.nvim)
palette ("night" variant, by folke — originally enkia's Tokyo Night VS Code
theme). The bar floats: a detached, rounded, near-opaque slab with 12px
margins and an 8px drop from the top edge. No capsules, no separators —
just accent-colored text with generous spacing.

- **Left** — apple glyph in blue, then AeroSpace workspaces as plain
  numbers: focused = purple on a soft rounded chip, others muted.
  Fails soft when AeroSpace is absent.
- **Center** — frontmost app in foreground, plus a now-playing marquee
  (green music note, 130pt scrolling label) that hides when stopped.
- **Right** — wifi (blue), volume (purple), battery (green, red when
  low), clock (blue `%H:%M`).

Type is SF Pro Semibold 12.5. Entry point is `ybarrc.lua`, which
bootstraps the sketchybar compat shim from `../sketchybar-port`.

Structure and idioms follow the `examples/darxk` reference theme.
