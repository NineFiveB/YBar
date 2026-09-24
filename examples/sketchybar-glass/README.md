# sketchybar-glass

The flagship theme: a monochrome Liquid Glass bar that replaces the native
macOS menu bar outright — real `NSGlassEffectView` backdrops on macOS 26+
(clear for bar pills, frosted for popups), a near-black palette, and soft
corners.

It is not a standalone config. It is a **restyle layer over
[`../sketchybar-port`](../sketchybar-port)** — every item file is reused from
there verbatim, and only a handful of files in this directory differ
(`colors.lua`, `bar.lua`, `default.lua`, `settings.lua`,
`helpers/default_font.lua`, plus `ybarrc.lua`). Widget fixes land once and
both themes get them.

**The port must be installed beside it.** `ybarrc.lua` probes for
`../sketchybar-port/sketchybar.lua` and falls back to
`~/.config/ybar/themes/sketchybar-port`.

[`../ysuite`](../ysuite) layers on this directory in turn: its
`ybarrc.lua` splices this directory into `package.path` and resolves
`colors`, `default`, `settings` and `helpers.default_font` from here, so
renaming or removing one of those files changes ysuite as well (and it
refuses to start when this directory is missing altogether).

## The look

- **Bar** — height 40, near-black, bar-level `glass` (the behind-window
  backdrop for the whole strip), `fullscreen_show`.
- **`topmost = "on"`** puts the bar at status-bar level, *above* the native
  menu bar. With "Automatically hide and show the menu bar" on, macOS still
  reveals its bar at the top edge; at this level YBar covers it, with no
  private APIs and no SIP changes. Set `topmost = "off"` to get the native
  bar back.
- **Pills** — `background.glass` on every item: a real `NSGlassEffectView`
  backdrop under the pill on macOS 26+, an in-shader approximation below it.
- **No borders on the pills.** The specular rim *is* the edge treatment; a
  post-pass in `ybarrc.lua` zeroes every item and bracket ring the port's
  item files applied.
- **Palette** — pure neutral greys, no blue cast anywhere; states read through
  brightness and glyph shape rather than hue, with one exception:
  `colors.connected`, the green on the Wi-Fi and VPN "Connected" rows.
- **Type** — SF Pro for both text and numerals.

## Helpers and permissions

Identical to the port it layers on, including the two opt-in `make helpers`
builds for the app-menu swap and menu-bar extras widget: see
[`../sketchybar-port/README.md`](../sketchybar-port/README.md). Everything
else works from a `brew install` with no build step.

## Credits

Structure and every widget come from `../sketchybar-port`, which is credited in
the repository's [THIRD_PARTY.md](../../THIRD_PARTY.md). The glass treatment,
the monochrome palette and the border-stripping pass are this theme's own.

## Run

```sh
ybar -c examples/sketchybar-glass/ybarrc.lua
# or: ybar --config examples/sketchybar-glass/ybarrc.lua
# or, once installed:
ybar theme use sketchybar-glass
```

Both `-c` and `--config` work. The `windows` branch ships its own restyle of
this theme for Windows 11 Fluent, where the pills are Mica rather than Liquid
Glass — see [docs/WINDOWS.md](../../docs/WINDOWS.md).
