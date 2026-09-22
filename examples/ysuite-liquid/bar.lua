local colors = require("colors")

sbar.bar({
  height = 40,
  -- No full-bleed material: a bar-wide NSGlassEffectView frosts the strip.
  -- Pills keep their own glass. The strip itself stays clear.
  color = colors.transparent,
  glass = false,
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
