-- darxk — a YBar replication of the Waybar setup from
-- github.com/00Darxk/dotfiles: translucent dark bar, segmented rounded
-- capsules with per-module Catppuccin accents, inverted light pills for the
-- active workspace and window title, bold monospace type.
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
  height = 34,
  color = colors.bar_bg,
  padding_left = 4,
  padding_right = 4,
  fullscreen_show = true,
})

sbar.default({
  updates = "when_shown",
  icon = {
    font = { family = FONT, style = "Bold", size = 13.0 },
    color = colors.text,
    padding_left = 7,
    padding_right = 4,
  },
  label = {
    font = { family = FONT, style = "Bold", size = 12.0 },
    color = colors.text,
    padding_left = 2,
    padding_right = 7,
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
