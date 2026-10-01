# YBar for Raycast

Change how your [YBar](https://github.com/NineFiveB/YBar) status bar looks
without opening its config. The extension talks to the running bar over
its socket and edits only what the theme declares; untouched settings keep
following the theme.

- **YBar Settings**: every knob the running theme declares, grouped by
  section, with the theme's default shown on each row. Numbers, sizes and
  colors are text fields; switches toggle in place.
- **YBar Themes**: the themes the bar can switch to, with the current one
  marked. Switching reloads the bar in place.
- **YBar Widgets**: turn the bar's widgets on or off and move them toward
  or away from the clock.
- **Reload YBar**: re-run the config.

Needs YBar 0.4 or later running. Colors take `0xAARRGGBB`, `#RRGGBB` or
`#AARRGGBB`. A setting that shapes layout re-runs the config when saved;
the bar blinks once.

The user's values live in `~/.config/ybar/settings/<theme>.json`, written
by the bar, never by this extension.
