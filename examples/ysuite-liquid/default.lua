local settings = require("settings")
local colors = require("colors")

local D = require("helpers.tunable")({
  { key = "font.icon_size", type = "number", default = 14, min = 8, max = 32,
    label = "Icon size", section = "Fonts" },
  { key = "font.label_size", type = "number", default = 13, min = 8, max = 32,
    label = "Label size", section = "Fonts" },
  { key = "pill_corner_radius", type = "number", default = 20, min = 0, max = 30,
    label = "Pill corner radius", section = "Layout" },
  -- The rim and the pointer specular: over a plain wallpaper the system
  -- material alone has nothing to refract, and the edge is what reads as
  -- glass. The panel gets the same lit edge the pills have: frosted glass
  -- over a mostly uniform backdrop blurs to a uniform tone, so without the
  -- rim only the corners — where the geometry curves — show any material.
  { key = "sheen", type = "bool", default = true,
    label = "Lit glass rim on pills and popups", section = "Glass" },
  { key = "popup.corner_radius", type = "number", default = 16, min = 0, max = 30,
    label = "Popup corner radius", section = "Popups" },
  { key = "popup.blur", type = "number", default = 30, min = 0, max = 60,
    label = "Popup blur", section = "Popups" },
})

-- Mock pills: 28pt tall, 20pt corners, glass, no hard border.
sbar.default({
  updates = "when_shown",
  icon = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = D.font.icon_size,
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  label = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = D.font.label_size,
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  background = {
    height = settings.pill_height,
    corner_radius = D.pill_corner_radius,
    border_width = 0,
    glass = true,
    sheen = D.sheen,
  },
  popup = {
    blur_radius = D.popup.blur,
    background = {
      border_width = 0,
      corner_radius = D.popup.corner_radius,
      color = colors.popup.bg,
      glass = true,
      sheen = D.sheen,
    },
  },
  padding_left = 2,
  padding_right = 2,
})
