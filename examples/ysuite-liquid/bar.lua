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
  -- Not 6: the two ends are not symmetric. The right end carries the
  -- calendar's trailing group-padding spacer on top of this, and the left end
  -- lost its spacer with the Apple pill, so equal padding here left the first
  -- workspace 10pt closer to the edge than the clock. Measured to the visible
  -- capsule, rim included: 15pt at both ends.
  padding_left = 16,
})
