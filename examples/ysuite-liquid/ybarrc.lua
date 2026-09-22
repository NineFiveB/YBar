-- Liquid Glass mock from ysuite-web ("Liquid Glass on Metal").
-- Full-bleed glass strip, capsule pills, and the webpage's right-hand order:
-- CPU sparkline, Wi-Fi, Bluetooth, battery, clock. Item scripts come from
-- the sketchybar port; this directory only overrides bar, colors, defaults,
-- and which widgets load.
--
-- Install: `ybar theme use ysuite-liquid` (see docs/THEMES.md).

-- Port widgets (spaces, menus, calendar) branch on this so the glass theme
-- stays on its own markup.
YSUITE_LIQUID = true

local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
do
  local probe = io.open(PORT_DIR .. "/sketchybar.lua", "r")
  if probe then probe:close()
  else PORT_DIR = os.getenv("HOME") .. "/.config/ybar/themes/sketchybar-port" end
end
SKETCHYBAR_CONFIG = PORT_DIR

package.path = package.path
  .. ";" .. PORT_DIR .. "/?.lua"
  .. ";" .. PORT_DIR .. "/?/init.lua"

sbar = require("sketchybar")

sbar.begin_config()
require("bar")
require("default")
require("items")

sbar.set("/.*/", { background = { border_width = 0 } })
sbar.set("/space\\..*/", { icon = { highlight_color = 0xffffffff } })

sbar.end_config()

sbar.event_loop()
