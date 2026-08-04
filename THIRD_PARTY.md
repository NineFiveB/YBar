# Third-party code and assets

- `examples/sketchybar-port/helpers/menus/menus.c` and its makefile are
  adapted (with small memory-management fixes) from
  [FelixKratz/dotfiles](https://github.com/FelixKratz/dotfiles), GPL-3.0,
  Copyright (C) Felix Kratz.
- `examples/sketchybar-port/` is a port of a sketchybar configuration built
  on the example ecosystem around
  [FelixKratz/SketchyBar](https://github.com/FelixKratz/SketchyBar) (MIT) and
  [SbarLua](https://github.com/FelixKratz/SbarLua); helper scripts were
  rewritten for YBar but follow their structure. `helpers/app_icons.lua`
  maps app names to glyphs from
  [sketchybar-app-font](https://github.com/kvndrsslr/sketchybar-app-font)
  (the font itself is not vendored).
- `examples/darxk/` replicates the Waybar design from
  [00Darxk/dotfiles](https://github.com/00Darxk/dotfiles).
- The nord, gruvbox, tokyonight, dracula, and rose-pine themes use the
  palettes of the projects credited in each theme's README.
- Nerd Font glyph codepoints reference [Nerd Fonts](https://www.nerdfonts.com).

YBar itself is GPL-3.0; see LICENSE.
