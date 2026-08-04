-- tokyonight — the floating island bar. A detached, rounded, near-opaque
-- slab in Tokyo Night storm blues: no capsules, no separators, just plain
-- accent-colored text breathing on a dark island.
local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
package.path = config_dir .. "?.lua;" .. config_dir .. "?/init.lua;"
  .. PORT_DIR .. "/?.lua;" .. PORT_DIR .. "/?/init.lua;" .. package.path

local colors = require("colors")
sbar = require("sketchybar")

FONT = "SF Pro"   -- engine falls back if not resolvable

sbar.begin_config()

sbar.bar({
  height = 34,
  margin = 12,
  y_offset = 8,
  corner_radius = 14,
  color = colors.bg,
  padding_left = 10,
  padding_right = 10,
  fullscreen_show = true,
})

sbar.default({
  updates = "when_shown",
  icon = {
    font = { family = FONT, style = "Semibold", size = 12.5 },
    color = colors.fg,
    padding_left = 4,
    padding_right = 4,
  },
  label = {
    font = { family = FONT, style = "Semibold", size = 12.5 },
    color = colors.fg,
    padding_left = 2,
    padding_right = 4,
  },
  padding_left = 2,
  padding_right = 2,
})

require("items.left")
require("items.workspaces")
require("items.center")
require("items.right")

sbar.end_config()

sbar.event_loop()
