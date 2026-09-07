# sketchybar-glass

The flagship theme, and the one in the repository's screenshots: a monochrome
Liquid Glass bar that replaces the native macOS menu bar outright.

It is not a standalone config. It is a **restyle layer over
[`../sketchybar-port`](../sketchybar-port)** — every item file is reused from
there verbatim, and only six files in this directory differ: `colors.lua`,
`bar.lua`, `default.lua`, `settings.lua` and `helpers/default_font.lua`, which
shadow the port's versions through `package.path` precedence, plus `ybarrc.lua`,
the entry point, which wires the two directories together and applies the
theme's post-passes (below). That is the whole theme. The widget catalog, the helper binaries and the porting notes all live
in the port; see its [PORTING.md](../sketchybar-port/PORTING.md).

**The port must be installed beside it.** `ybarrc.lua` probes for
`../sketchybar-port/sketchybar.lua` and falls back to
`~/.config/ybar/themes/sketchybar-port`. In a clone the sibling directory
satisfies it; installed through `ybar-theme`, install `sketchybar-port` too.

## The look

- **Bar** — height 40, near-black `0xd9121214`, bar-level `glass` (the
  behind-window backdrop for the whole strip), `fullscreen_show`.
- **`topmost = "on"`** puts the bar at status-bar level, *above* the native
  menu bar. With "Automatically hide and show the menu bar" on, macOS still
  reveals its bar at the top edge; at this level YBar covers it, with no
  private APIs and no SIP changes. The trade-off is that the native status
  items become unclickable while covered — which is why the theme ships
  replacements for them (Apple menu, app menus, wifi, bluetooth, battery,
  calendar). Set `topmost = "off"` to get the native bar back.
- **Pills** — `background.glass` on every item: a real `NSGlassEffectView`
  backdrop under the pill on macOS 26+, an in-shader approximation below it,
  tinted by the pill's own barely-there fill. 9pt corners, 28pt tall.
- **No borders on the pills.** The specular rim *is* the edge treatment, so
  sketchybar's border rings would read as outlines through the glass. A
  post-pass in `ybarrc.lua` zeroes every item and bracket ring the port's item
  files applied: `sbar.set("/.*/", { background = { border_width = 0 } })`.
  Popup rings are a separate property the post-pass does not reach:
  `default.lua` sets `popup.background.border_width = 0`, but the port's
  `items/spaces.lua` and `items/spaces_yabai.lua` set a 5pt ring per workspace
  item that overrides the default and survives.
- **Popups** — `blur_radius = 30` with a glass background at the same tint as
  the pills, so there is one material everywhere.
- **Palette** — pure neutral greys, no blue cast anywhere; states read through
  brightness and glyph shape rather than hue. `colors.lua` keeps the port's
  key names exactly, which is what lets the item files run unchanged.
- **Type** — SF Pro for both text and numerals. The port pairs SF Pro with SF
  Mono; the native menu bar uses SF Pro for both, so this theme does too.

## Credits

Structure and every widget come from `../sketchybar-port`, which is credited in
the repository's [THIRD_PARTY.md](../../THIRD_PARTY.md). The glass treatment,
the monochrome palette and the border-stripping pass are this theme's own.

## Run

```sh
ybar -c examples/sketchybar-glass/ybarrc.lua      # or: scripts/ybar-theme use sketchybar-glass
```

Both `-c` and `--config` work. The `windows` branch ships its own restyle of
this theme for Windows 11 Fluent, where the pills are Mica rather than Liquid
Glass — see [the README's Windows section](../../README.md#windows).
