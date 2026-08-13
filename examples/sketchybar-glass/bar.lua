local colors = require("colors")

sbar.bar({
  height = 40,
  color = colors.bar.bg,
  -- Fluent minimal: a dark, near-opaque strip with NO Acrylic backdrop —
  -- the Windows default look is flat, not glass (the macOS theme keeps its
  -- Liquid Glass treatment; this is the deliberate Windows divergence).
  glass = false,
  fullscreen_show = true,
  -- On macOS this level covers the native menu bar so the theme can replace
  -- it. Windows has no menu bar to cover; topmost=on simply keeps the strip
  -- above normal windows, and reserve (komorebi offset or the appbar) keeps
  -- tiled/maximized windows out from underneath it.
  topmost = "on",
  padding_right = 2,
  padding_left = 2,
})
