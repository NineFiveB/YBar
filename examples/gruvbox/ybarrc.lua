-- gruvbox — retro powerline status bar. Solid full-height colored blocks
-- (morhetz/gruvbox dark palette) with dark bold text, chained together by
-- powerline arrow separators so the segments flow into each other. Opaque
-- bar, zero margin, zero radius: pure terminal-statusline nostalgia.
local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
do
  -- Installed via ybar-theme (outside the repo): the shim lives in the
  -- shared themes dir instead of a sibling.
  local probe = io.open(PORT_DIR .. "/sketchybar.lua", "r")
  if probe then probe:close()
  else PORT_DIR = os.getenv("HOME") .. "/.config/ybar/themes/sketchybar-port" end
end
package.path = config_dir .. "?.lua;" .. config_dir .. "?/init.lua;"
  .. PORT_DIR .. "/?.lua;" .. PORT_DIR .. "/?/init.lua;" .. package.path

local colors = require("colors")
sbar = require("sketchybar")

FONT = "JetBrainsMono Nerd Font"   -- engine falls back if not installed

sbar.begin_config()

sbar.bar({
  notch_width = 0,   -- auto-detect the housing on notched Macs
  height = 30,
  color = colors.bar_bg,
  margin = 0,
  y_offset = 0,
  corner_radius = 0,
  padding_left = 0,
  padding_right = 0,
  fullscreen_show = true,
})

sbar.default({
  updates = "when_shown",
  icon = {
    font = { family = FONT, style = "Bold", size = 12.0 },
    color = colors.fg,
    padding_left = 8,
    padding_right = 4,
  },
  label = {
    font = { family = FONT, style = "Bold", size = 12.0 },
    color = colors.fg,
    padding_left = 2,
    padding_right = 8,
  },
  padding_left = 0,
  padding_right = 0,
})

require("items.workspaces")
require("items.left")
require("items.right")

sbar.end_config()

sbar.event_loop()
