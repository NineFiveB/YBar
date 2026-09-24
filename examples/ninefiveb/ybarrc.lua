-- NineFiveB daily driver — the maintainer setup running on the development
-- Mac. Liquid Glass over the full sketchybar-port widget suite (apple menu,
-- app menus + workspace swap, AeroSpace workspaces with app icons, calendar,
-- battery + charge history, bluetooth, wifi with CoreWLAN SSID recovery,
-- CPU / memory gauges, now-playing).
--
-- Differs from sketchybar-glass only in bar geometry: full-width strip
-- (margin=0, y_offset=0) so topmost=on can cover the native menu bar without
-- edge leaks. Only bar.lua lives here; colors, defaults and fonts resolve
-- from ../sketchybar-glass and the item files from ../sketchybar-port.
--
-- Install: `ybar theme use ninefiveb` (see docs/THEMES.md).

local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
do
  local probe = io.open(PORT_DIR .. "/sketchybar.lua", "r")
  if probe then probe:close()
  else PORT_DIR = os.getenv("HOME") .. "/.config/ybar/themes/sketchybar-port" end
end
SKETCHYBAR_CONFIG = PORT_DIR

-- colors / default / settings / helpers.default_font come from the glass
-- theme rather than a copy here, so a palette fix lands once. Same lookup
-- as the port: beside this theme in the repo, else under ~/.config/ybar/themes.
local GLASS_DIR = config_dir .. "../sketchybar-glass"
do
  local probe = io.open(GLASS_DIR .. "/colors.lua", "r")
  if probe then probe:close()
  else GLASS_DIR = os.getenv("HOME") .. "/.config/ybar/themes/sketchybar-glass" end
end

-- Search order: this directory, the glass theme, then the Lua default path
-- and the port. The engine already put this directory first, but the glass
-- entry has to go in FRONT of package.path rather than on the end: the
-- vendored default path ends in ./?.lua, and the port carries its own
-- colors / default / settings / default_font, so an appended entry would
-- lose to both. Re-adding this directory ahead of it keeps bar.lua here
-- winning over the glass island one; the duplicate entry is harmless.
package.path = config_dir .. "?.lua;"
  .. GLASS_DIR .. "/?.lua;"
  .. package.path
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
