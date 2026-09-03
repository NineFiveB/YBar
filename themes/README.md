# themes

Ported YBar themes with komorebi workspace widgets ship under `examples/`
(`catppuccin-komorebi`, `sketchybar-glass`) — that is what CI and the release
workflow stage beside `ybar.exe`, and the first place `ybar theme list` looks
(a `themes\` folder beside the exe and `~/.config/ybar/themes` come next);
the theme model (entry-point search `ybarrc.lua` → `ybar.jsonc` → `ybarrc.jsonc`,
~/.config/ybar/themes, `current-theme` file) is defined
in docs/WINDOWS-PORT.md section 12.
