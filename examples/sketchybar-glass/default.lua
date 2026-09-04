local settings = require("settings")
local colors = require("colors")

-- The port's defaults restyled Fluent-minimal for Windows: flat rounded
-- pills (no glass rim, no Acrylic), subtle single-tone fills, no borders —
-- the macOS tree keeps its Liquid Glass treatment; this divergence is the
-- point (Windows' default design language is flat Fluent).
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
    -- Item-level glass is the shader's bevel lighting, NOT a backdrop: a
    -- quarter-round edge lit from above, highlight on the top arc and shade
    -- under the bottom. It costs no extra draw and no backdrop of any kind.
    -- The BAR's own glass stays off in bar.lua -- that flag is the DWM Acrylic
    -- plate, which is a completely different thing and the part that reads
    -- dated on a near-black strip.
    glass = true,
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
