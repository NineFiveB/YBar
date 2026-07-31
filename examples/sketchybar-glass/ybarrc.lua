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

PORT_DIR = os.getenv("HOME") .. "/Documents/Development/YBar/examples/sketchybar-port"
SKETCHYBAR_CONFIG = os.getenv("HOME") .. "/Documents/Development/sketchybar-setup/config"

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

sbar.end_config()

sbar.event_loop()
