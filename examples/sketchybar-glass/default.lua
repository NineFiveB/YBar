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
      size = 14.0
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  label = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Semibold"],
      size = 13.0
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  background = {
    height = 28,
    corner_radius = 8, -- Fluent "overlay corner" radius
    border_width = 0,
    glass = false,
  },
  popup = {
    blur_radius = 0, -- no Acrylic behind popups: solid Fluent panels
    background = {
      border_width = 0,
      corner_radius = 8,
      color = colors.popup.bg,
      glass = false,
    },
  },
  -- Tight outer paddings: 4pt between adjacent pills (was 10).
  padding_left = 2,
  padding_right = 2,
})
