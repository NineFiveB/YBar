-- YbarLua port of the ShishaKnight/SketchyBar-Setup configuration.
-- Install:
--   mkdir -p ~/.config/ybar
--   cp -R examples/sketchybar-port/* ~/.config/ybar/
--   mv ~/.config/ybar/ybarrc.lua ~/.config/ybar/ybarrc.lua   (already named)
--
-- The original SbarLua files run almost verbatim through the compat shim
-- (sketchybar.lua). Deltas from the original are marked "YBAR PORT".

-- YBAR PORT: helper binaries/scripts (menus, calendar events, bluetooth
-- battery, system stats, AltServer click) still live in the original
-- sketchybar tree — adjust if yours is elsewhere.
-- Helpers are vendored in THIS directory.
SKETCHYBAR_CONFIG = (debug.getinfo(1, "S").source:match("@?(.*/)") or "./"):gsub("/$", "")

sbar = require("sketchybar")

sbar.begin_config()
require("bar")
require("default")
require("items")
sbar.end_config()

sbar.event_loop() -- no-op under YBar; kept for symmetry with the original
