-- rose-pine — an airy, quiet YBar theme in the Rosé Pine palette
-- (rosepinetheme.com): plain text on a translucent base, no capsules, no
-- pills, workspaces as soft dots. Everything whispers.
local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
package.path = config_dir .. "?.lua;" .. config_dir .. "?/init.lua;"
  .. PORT_DIR .. "/?.lua;" .. PORT_DIR .. "/?/init.lua;" .. package.path

local colors = require("colors")
sbar = require("sketchybar")

FONT = "SF Pro"   -- engine falls back if not installed

sbar.begin_config()

sbar.bar({
  height = 32,
  color = colors.base,
  margin = 0,
  padding_left = 12,
  padding_right = 12,
  fullscreen_show = true,
})

sbar.default({
  updates = "when_shown",
  icon = {
    font = { family = FONT, style = "Regular", size = 12.0 },
    color = colors.text,
    padding_left = 0,
    padding_right = 4,
  },
  label = {
    font = { family = FONT, style = "Regular", size = 12.0 },
    color = colors.muted,
    padding_left = 0,
    padding_right = 0,
  },
  padding_left = 6,
  padding_right = 6,
})

require("items.workspaces")
require("items.left")
require("items.right")

sbar.end_config()

sbar.event_loop()
