local colors = require("colors")

sbar.bar({
  height = 40,
  color = colors.bar.bg,
  glass = true,
  fullscreen_show = true,
  -- Status-bar window level, which sits ABOVE the native menu bar's level.
  -- With "Automatically hide and show the menu bar" on, macOS still reveals
  -- its menu bar when the pointer reaches the top edge - right where this bar
  -- lives. At the default (behind-windows) level that revealed menu bar draws
  -- over YBar; at this level YBar covers it, so the native bar is never
  -- visible. No private APIs and no SIP changes needed - the reason yabai
  -- reaches for SkyLight's menubar_opacity is that it has no bar of its own
  -- to cover it with.
  --
  -- Trade-off: the native menu bar and its status items (Control Center, the
  -- system clock, third-party menu items) become unclickable while covered.
  -- This theme replaces them - Apple menu, app menus via the menus swap, and
  -- the wifi/bluetooth/battery/calendar widgets. Set topmost = "off" to get
  -- the native bar back.
  topmost = "on",
  padding_right = 2,
  padding_left = 2,
})
