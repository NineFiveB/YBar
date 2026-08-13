-- YBar Liquid Glass theme — the Windows port of the macOS flagship.
-- Every element with a Windows analog is here in the same placement: the
-- system menu (the apple menu's stand-in), komorebi workspaces, front app,
-- calendar, battery + popup, bluetooth, wifi + details, cpu + stats popup,
-- media — restyled as dark Liquid Glass: an Acrylic bar backdrop, specular
-- rims, soft corners.
--
-- Differences from the macOS tree, all OS-inherent (see PORTING-WIN.md):
-- the app-menu swap and status-item capture have no Windows concept, the
-- calendar popup lists no events (EventKit), workspaces come from komorebi's
-- event env rather than a CLI probe, and this directory is self-contained —
-- the item files are vendored here instead of overlaying ../sketchybar-port.

local config_dir = debug.getinfo(1, "S").source
  :match("@?(.*[/\\])") or ".\\"
package.path = package.path
  .. ";" .. config_dir .. "?.lua"
  .. ";" .. config_dir .. "?/init.lua"

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
