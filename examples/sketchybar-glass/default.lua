local settings = require("settings")
local colors = require("colors")

-- The port's defaults with the glass treatment: 20pt macOS-26 corners,
-- in-shader glass material (implies a blurred backdrop on every pill),
-- no hard borders — the specular rim replaces them.
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
    corner_radius = 20,
    border_width = 0,
    glass = true,
  },
  popup = {
    blur_radius = 30,
    background = {
      border_width = 0,
      corner_radius = 20,
      color = colors.popup.bg,
      glass = true,
    },
  },
  padding_left = 5,
  padding_right = 5,
})
