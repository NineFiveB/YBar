-- YSuite daily driver — the maintainer setup running on the development
-- Mac. Liquid Glass over the full sketchybar-port widget suite (apple menu,
-- app menus + workspace swap, AeroSpace workspaces with app icons, calendar,
-- battery + charge history, bluetooth, wifi with CoreWLAN SSID recovery,
-- CPU / memory gauges, now-playing).
--
-- Differs from sketchybar-glass only in bar geometry: full-width strip
-- (margin=0, y_offset=0) so topmost=on can cover the native menu bar without
-- edge leaks. Colors, fonts, and the port item files are shared.
--
-- Install: `ybar theme use ysuite` (see docs/THEMES.md).

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

-- Specular rim is the edge treatment — strip sketchybar border strokes.
sbar.set("/.*/", { background = { border_width = 0 } })
sbar.set("/space\\..*/", { icon = { highlight_color = 0xffffffff } })

sbar.end_config()

sbar.event_loop()
