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

-- Bevel lighting on every widget pill: item-level glass, the quarter-round
-- rim lit from above. Set by NAME on the seven brackets rather than through
-- default.lua so it never reaches popup rows, the 2pt separators or the
-- slider plates. The workspace strip is deliberately absent: paint_space owns
-- its pills' glass and lights only the focused one, so focus keeps reading as
-- "the lit pill" -- and with the shader's luminance scaling that lit rim is
-- brighter on the grey focus fill than on these dark ones anyway.
sbar.set("/(widgets\\..*|calendar)\\.bracket/", { background = { glass = true } })

-- Focused-workspace highlight: brightest white (monochrome scheme).
sbar.set("/space\\..*/", { icon = { highlight_color = 0xffffffff } })

-- Popup open/close fade, in frames at 60Hz. Applied here rather than in
-- default.lua because ItemStore's applyDefaults copies an explicit field
-- list and `popup` is not on it, so popup defaults never reach an item.
--
-- Asymmetric, and the opposite way round from hover: a panel is usually
-- dismissed involuntarily — the pointer merely leaving the bar — so a slow
-- exit trails ghost panels behind a pointer sweeping across the pills.
sbar.set("/.*/", { popup = { fade_in = 8, fade_out = 5 } })

sbar.end_config()

sbar.event_loop()
