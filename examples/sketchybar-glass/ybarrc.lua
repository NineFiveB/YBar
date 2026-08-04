-- YBar Liquid Glass theme over the FULL sketchybar-setup port.
-- Every element and placement is identical to the sketchybar config (apple
-- menu, app menus + workspace swap, workspaces with app icons, calendar,
-- AltServer, battery + popup + charge slider, bluetooth, wifi + speeds,
-- cpu + stats popup) — restyled as dark Liquid Glass: blurred backdrops,
-- specular rims, 20pt macOS-26 corners.
--
-- The item files are REUSED verbatim from ../sketchybar-port; only this
-- directory's colors.lua / bar.lua / default.lua differ.
--
-- Install:
--   cp -R examples/sketchybar-port ~/.config/ybar-port-files
--   cp -R examples/sketchybar-glass/* ~/.config/ybar/
--   (then adjust PORT_DIR below to ~/.config/ybar-port-files)

-- The port tree ships beside this theme in the repo; a theme installed via
-- ybar-theme lands in ~/.config/ybar/themes instead, so fall back there.
local config_dir = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
PORT_DIR = config_dir .. "../sketchybar-port"
do
  local probe = io.open(PORT_DIR .. "/sketchybar.lua", "r")
  if probe then probe:close()
  else PORT_DIR = os.getenv("HOME") .. "/.config/ybar/themes/sketchybar-port" end
end
-- All helpers are vendored with the port — the config is self-contained.
SKETCHYBAR_CONFIG = PORT_DIR

-- The glass dir (already first on package.path) wins for colors/bar/default;
-- everything else (compat shim, items, helpers, settings, icons) comes from
-- the port.
package.path = package.path
  .. ";" .. PORT_DIR .. "/?.lua"
  .. ";" .. PORT_DIR .. "/?/init.lua"

sbar = require("sketchybar")

sbar.begin_config()
require("bar")
require("default")
require("items")

-- Glass post-pass: the specular rim IS the edge treatment — sketchybar's
-- border rings (item borders + bracket double-borders) read as outlines
-- through glass. Strip every stroke the item files applied.
sbar.set("/.*/", { background = { border_width = 0 } })

-- Focused-workspace highlight: brightest white (monochrome scheme).
sbar.set("/space\\..*/", { icon = { highlight_color = 0xffffffff } })

sbar.end_config()

sbar.event_loop()
