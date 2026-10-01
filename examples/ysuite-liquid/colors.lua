-- Liquid Glass mock palette from ysuite-web `.ybar-mac-*`.
-- Same keys as the port's colors.lua so every item file works unchanged.
-- The entries a user is likely to want are declared for the settings app;
-- the rest are shades derived from the mock and stay literal.
local C = require("helpers.tunable")({
  { key = "colors.text", type = "color", default = 0xffffffff,
    label = "Text", section = "Colors" },
  -- The palette is monochrome by design — red, green and blue are all
  -- shades of white. Today's date is the one place that has to read as an
  -- accent, so its number gets a real red rather than the brightest grey.
  -- Opaque: it is ink on the selection wash, not a fill.
  { key = "colors.today", type = "color", default = 0xffff453a,
    label = "Today's date", section = "Colors" },
  -- The focused workspace pill. A WASH, not a plate: it is laid over the
  -- pill's own glass so the material keeps refracting and the rim stays lit,
  -- and the selection reads as that capsule lifting rather than turning grey.
  -- Light rather than dark, because the strip sits over the wallpaper and a
  -- darker capsule reads as recessed; a theme over a near-black bar would
  -- take the other direction. Keep the alpha low enough that the material
  -- still shows through — an opaque value here is the flat plate again.
  { key = "colors.space_selected", type = "color", default = 0x26ffffff,
    label = "Focused workspace wash", section = "Colors" },
  { key = "colors.connected", type = "color", default = 0xff30d158,
    label = "Connected", section = "Colors" },
  -- Selection plates and gray capsules. Black wash and a low white, so they
  -- sit darker than a bright frost on the glass popup.
  { key = "colors.selection", type = "color", default = 0x50000000,
    label = "Selection plates", section = "Colors" },
  { key = "colors.button", type = "color", default = 0x2cffffff,
    label = "Buttons", section = "Colors" },
  { key = "colors.popup", type = "color", default = 0x212a2a2a,
    label = "Popup panel", section = "Colors" },
  -- Pills: keep alpha above ~0.02 so glass backdrops still attach, but light
  -- enough that inactive frost stays refractive instead of a solid plate.
  { key = "colors.pill", type = "color", default = 0x152a2a2a,
    label = "Pill fill", section = "Colors" },
  { key = "colors.pill_lifted", type = "color", default = 0x28383838,
    label = "Pill fill, hovered", section = "Colors" },
  { key = "colors.row_hover", type = "color", default = 0x16ffffff,
    label = "Popup row, hovered", section = "Colors" },
}).colors

return {
  black = 0x26000000,
  white = C.text,
  red = 0xffffffff,
  green = 0xffe4e4e4,
  blue = 0xffd2d2d2,
  yellow = 0xfff0f0f0,
  orange = 0xffe8e8e8,
  magenta = 0xffd8d8d8,
  grey = 0xff8e8e8e,
  connected = C.connected,
  today = C.today,
  transparent = 0x00000000,
  selection = C.selection,
  button = C.button,
  -- Leaving the key out keeps the old painted highlight.
  space_selected = C.space_selected,

  bar = {
    -- Unused by ysuite-liquid's bar.lua (the strip is fully clear). Kept so
    -- other item files can still read colors.bar.bg.
    bg = 0x00000000,
    border = 0x00000000,
  },
  popup = {
    bg = C.popup,
    border = 0x2effffff,
  },
  bg1 = C.pill,
  bg2 = C.pill_lifted,
  row_hover = C.row_hover,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
