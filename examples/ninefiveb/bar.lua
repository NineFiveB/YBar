local colors = require("colors")

sbar.bar({
  height = 40,
  color = colors.bar.bg,
  glass = true,
  fullscreen_show = true,
  -- Full-width strip under topmost=on. A window-level margin / y_offset would
  -- leave gaps where the native menu bar shows through (top band, side
  -- columns, transparent rounded corners). The painted island experiment
  -- lives on sketchybar-glass; this daily driver keeps the cover solid.
  margin = 0,
  y_offset = 0,
  corner_radius = 9,
  -- Status-bar window level, which sits ABOVE the native menu bar's level.
  -- With "Automatically hide and show the menu bar" on, macOS still reveals
  -- its menu bar when the pointer reaches the top edge - right where this bar
  -- lives. At the default (behind-windows) level that revealed menu bar draws
  -- over YBar; at this level YBar covers it, so the native bar is never
  -- visible. No private APIs and no SIP changes needed.
  --
  -- Trade-off: the native menu bar and its status items become unclickable
  -- while covered. This theme replaces them — Apple menu, app menus via the
  -- menus swap, and the wifi/bluetooth/battery/calendar widgets. Set
  -- topmost = "off" to get the native bar back.
  topmost = "on",
  padding_right = 2,
  padding_left = 2,
})
