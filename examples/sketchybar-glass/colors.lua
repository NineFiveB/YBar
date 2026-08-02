-- Monochrome glass palette: pure neutral greys over the near-black strip —
-- no blue casts anywhere; states read through brightness and glyph shape.
-- Same keys as the port's colors.lua so every item file works unchanged.
return {
  black = 0x26000000,        -- borders melt into soft shadow lines
  white = 0xffffffff,
  red = 0xffffffff,          -- emphasis / alert -> brightest
  green = 0xffe4e4e4,        -- positive -> near-white
  blue = 0xffd2d2d2,         -- info / graphs -> light grey
  yellow = 0xfff0f0f0,       -- warning -> bright
  orange = 0xffe8e8e8,
  magenta = 0xffd8d8d8,
  grey = 0xff8e8e8e,         -- secondary
  transparent = 0x00000000,

  bar = {
    bg = 0xd9121214,         -- near-black over the glass strip
    border = 0x00000000,
  },
  popup = {
    bg = 0x212a2a2a,         -- same tint as the pills: one material everywhere
    border = 0x2effffff,
  },
  -- True Tahoe glass is mostly backdrop: barely-there neutral tints, the
  -- blur and the specular rim carry the material.
  bg1 = 0x212a2a2a,          -- ~13%, luma-matched to the old blue-grey
  bg2 = 0x2e383838,          -- ~18%

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
