local colors = require("colors")

sbar.bar({
  height = 35,
  color = colors.bar.bg,
  -- A dark, near-opaque strip with NO Acrylic backdrop: the material lives on
  -- the pills (item-level glass = Mica, see default.lua), and a strip that was
  -- itself glass would leave them nothing to stand out against. Bar-level
  -- glass is DWM Acrylic and follows the Transparency-effects setting; the
  -- pills' Mica does not need it.
  glass = false,
  -- Auto-hide the bar on a monitor while an app is fullscreen there (and show
  -- it again on a non-fullscreen workspace) — the Windows-taskbar convention.
  -- Set fullscreen_show = true to instead keep the bar raised over fullscreen.
  fullscreen_show = false,
  -- On macOS this level covers the native menu bar so the theme can replace
  -- it. Windows has no menu bar to cover; topmost=on simply keeps the strip
  -- above normal windows, and reserve (komorebi offset or the appbar) keeps
  -- tiled/maximized windows out from underneath it.
  topmost = "on",
  padding_right = 2,
  padding_left = 2,
})
