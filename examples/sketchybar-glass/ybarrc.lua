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
local colors = require("colors")

sbar.begin_config()
require("bar")
require("default")
require("items")

-- Glass post-pass: the specular rim IS the edge treatment — sketchybar's
-- border rings (item borders + bracket double-borders) read as outlines
-- through glass. Strip every stroke the item files applied.
sbar.set("/.*/", { background = { border_width = 0 } })

-- Glass on every widget pill. On Windows that is Mica -- a wallpaper-material
-- visual composed under the pill, tinted by the pill's own translucent fill
-- (colors.mica) -- plus the shader's quarter-round rim lit from above. Set by
-- NAME rather than through default.lua so it never reaches popup rows, the
-- 2pt separators or the slider plates. The calendar is named as the ITEM: its
-- bracket is transparent, and the fill that becomes the tint lives on the
-- item. Anchored, because a name pattern is a SEARCH (item.cpp: unanchored
-- regex_search): a bare `calendar` would also match every calendar.* popup
-- row and put the rim on today's cell and the separator. The workspace strip
-- is deliberately absent: paint_space owns its pills' glass and lights only
-- the focused one, so focus keeps reading as "the material pill" among flat
-- ones.
sbar.set("/^(widgets\\..*\\.bracket|calendar)$/", { background = { glass = true } })

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

-- Mica panels: the popup plate is a translucent tint (colors.popup.bg) over
-- a wallpaper-material visual, with the shader's rim on its edge -- the same
-- material as the pills, on the seven popup hosts by name (the calendar's
-- popup opens on its BRACKET, so that is the host here). Rows keep their
-- flat fills; only the panel is material. Set here for the same reason as
-- the fade: default.lua's popup table never reaches an item.
sbar.set("/^(widgets\\..*\\.bracket|calendar\\.bracket)$/", {
  popup = { background = { color = colors.popup.bg, glass = true } },
})

sbar.end_config()

sbar.event_loop()
