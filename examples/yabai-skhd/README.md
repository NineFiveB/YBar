# YBar + yabai + skhd

The example config's workspace pills auto-detect the window manager:
AeroSpace when installed, otherwise yabai (`items/spaces_yabai.lua`,
native macOS Spaces).

- **`yabairc`** — signal recipes that push space/window changes to the bar
  instantly. Without them the adapter still works from NSWorkspace space
  events plus a 5-second poll; with them, window creates/destroys/minimizes
  repaint immediately. The `ybar` CLI folds every `$YABAI_*` signal variable
  into the trigger's env automatically.
- **`skhdrc`** — mode declarations that drive the bar's mode indicator pill
  (`widgets.skhd_mode`, hidden in default mode), plus a common yabai
  binding starter set.

Any skhd binding can drive the bar directly: `ybar --trigger <event>
KEY=value`, `ybar --set <item> ...`, `ybar --bar hidden=toggle` — the full
CLI surface is available from hotkeys.
