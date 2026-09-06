local settings = require("settings")
local colors = require("colors")

-- The port's defaults restyled for Windows: rounded pills with no borders on
-- a flat strip with no Acrylic; glass is off HERE and switched on by name in
-- ybarrc.lua for the widget pills, where on Windows it is Mica (a wallpaper
-- material under a translucent tint, plus the shader's lit rim) rather than
-- the macOS tree's Liquid Glass.
sbar.default({
  updates = "when_shown",
  icon = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Bold"],
      size = 12.5
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  label = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Semibold"],
      size = 11.5
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  background = {
    height = 25,
    -- Windows 11's OverlayCornerRadius, the radius its top-level windows and
    -- flyouts use. Matching the OS matters more here than the smoother rim a
    -- bigger radius buys: a full stadium looked better in isolation and wrong
    -- next to everything else on screen.
    --
    -- The smoothness cost is real but small, and is no longer the main term.
    -- Where a corner arc meets a straight edge the curvature jumps from 1/r to
    -- 0, and the bevel normal follows the SDF gradient, so the highlight
    -- inherits that break -- a tighter radius packs it into fewer pixels. What
    -- actually made the rim look choppy was the hard clamp in the shader,
    -- which is now a tanh knee. The principled fix for the rest is a squircle
    -- (continuous curvature) via background.corner_exponent, which the model
    -- parses but v1 still renders circular.
    corner_radius = 8,
    border_width = 0,
    -- Item-level glass on Windows is Mica: a wallpaper-material visual under
    -- the pill, tinted by the pill's own translucent fill, plus the shader's
    -- bevel rim (a quarter-round edge lit from above). Off by default so it
    -- never reaches popup rows or separators; ybarrc.lua turns it on by name
    -- for the widget pills, with colors.mica as their fill. The BAR's own
    -- glass in bar.lua is a different thing entirely (the DWM Acrylic plate,
    -- which also honours the Transparency-effects setting) and stays off.
    glass = false,
  },
  popup = {
    blur_radius = 0, -- no Acrylic behind popups: solid Fluent panels
    -- NOTE: nothing in this `popup` table actually applies. ItemStore's
    -- applyDefaults copies an explicit field list (a reference contract) and
    -- `popup` is not on it, so these are inert — the panels are getting the
    -- engine's built-in PopupState defaults instead. Kept as the statement of
    -- intent it has always been; the open/close fade that has to take effect
    -- is applied by name in ybarrc.lua after the items load.
    background = {
      border_width = 0,
      corner_radius = 8, -- OverlayCornerRadius again: a popup is a flyout
      color = colors.popup.bg,
      glass = false,
    },
  },
  -- Tight outer paddings: 4pt between adjacent pills (was 10).
  padding_left = 2,
  padding_right = 2,
})
