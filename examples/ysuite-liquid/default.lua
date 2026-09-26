local settings = require("settings")
local colors = require("colors")

-- Mock pills: 28pt tall, 20pt corners, glass, no hard border.
sbar.default({
  updates = "when_shown",
  icon = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = 14.0
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  label = {
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = 13.0
    },
    color = colors.white,
    padding_left = settings.paddings,
    padding_right = settings.paddings,
  },
  background = {
    height = settings.pill_height,
    corner_radius = 20,
    border_width = 0,
    glass = true,
    -- The rim and the pointer specular: over a plain wallpaper the system
    -- material alone has nothing to refract, and the edge is what reads as
    -- glass.
    sheen = true,
  },
  popup = {
    blur_radius = 30,
    background = {
      border_width = 0,
      corner_radius = 16,
      color = colors.popup.bg,
      glass = true,
      -- The panel gets the same lit edge the pills have. Frosted glass over a
      -- mostly uniform backdrop blurs to a uniform tone, so without the rim
      -- only the corners — where the geometry curves — show any material.
      sheen = true,
    },
  },
  padding_left = 2,
  padding_right = 2,
})
