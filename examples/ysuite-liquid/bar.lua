local colors = require("colors")

sbar.bar({
  height = 40,
  color = colors.bar.bg,
  glass = true,
  fullscreen_show = true,
  -- Full-bleed strip, matching the webpage mock. A window inset would leak
  -- the native menu bar under topmost=on.
  margin = 0,
  y_offset = 0,
  corner_radius = 0,
  topmost = "on",
  padding_right = 6,
  padding_left = 6,
})
