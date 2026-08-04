-- dracula — colorful blocks: every module rides its own bright rounded
-- block with dark text on a translucent Dracula-dark bar.
-- Palette: draculatheme.com (Zeno Rocha and contributors).
local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
package.path = config_dir .. "?.lua;" .. config_dir .. "?/init.lua;"
  .. PORT_DIR .. "/?.lua;" .. PORT_DIR .. "/?/init.lua;" .. package.path

local colors = require("colors")
sbar = require("sketchybar")

FONT = "JetBrainsMono Nerd Font"   -- engine falls back if not installed

sbar.begin_config()

sbar.bar({
  height = 34,
  color = colors.bar_bg,
  margin = 0,
  padding_left = 6,
  padding_right = 6,
  fullscreen_show = true,
})

sbar.default({
  updates = "when_shown",
  icon = {
    font = { family = FONT, style = "Bold", size = 12.0 },
    color = colors.bg,
    padding_left = 8,
    padding_right = 4,
  },
  label = {
    font = { family = FONT, style = "Bold", size = 12.0 },
    color = colors.bg,
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
