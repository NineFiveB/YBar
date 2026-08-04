-- nord — the classic Nord Waybar look on YBar: a flat, fully opaque,
-- full-width polar-night strip. No pills, no capsules — plain "icon value"
-- modules divided by thin separators, workspaces as bare numbers on the left.
local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
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
  corner_radius = 0,
  y_offset = 0,
  padding_left = 8,
  padding_right = 8,
  fullscreen_show = true,
})

sbar.default({
  updates = "when_shown",
  icon = {
    font = { family = FONT, style = "Regular", size = 12.0 },
    color = colors.frost,
    padding_left = 6,
    padding_right = 4,
  },
  label = {
    font = { family = FONT, style = "Regular", size = 12.0 },
    color = colors.text,
    padding_left = 2,
    padding_right = 6,
  },
  padding_left = 0,
  padding_right = 0,
})

require("items.workspaces")
require("items.left")
require("items.right")

sbar.end_config()

sbar.event_loop()
