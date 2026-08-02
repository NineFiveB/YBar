-- Liquid Glass palette: sonokai accents over translucent dark glass.
-- Same keys as the port's colors.lua so every item file works unchanged.
return {
  black = 0x26000000,        -- borders melt into soft shadow lines
  -- Monochrome: states read through brightness and glyph shape, not hue.
  white = 0xffffffff,
  red = 0xffffffff,          -- emphasis / alert -> brightest
  green = 0xffe2e2e6,        -- positive -> near-white
  blue = 0xffd0d0d6,         -- info / graphs -> light grey
  yellow = 0xfff0f0f2,       -- warning -> bright
  orange = 0xffe6e6ea,
  magenta = 0xffd6d6dc,
  grey = 0xff8e8e93,         -- secondary
  transparent = 0x00000000,

  bar = {
    bg = 0xb31c1c1e,         -- native menu bar darkness over the glass strip
    border = 0x00000000,
  },
  popup = {
    bg = 0x21262b36,         -- same tint as the pills: one material everywhere
    border = 0x2effffff,
  },
  -- True Tahoe glass is mostly backdrop: barely-there neutral tints, the
  -- blur and the specular rim carry the material.
  bg1 = 0x21262b36,          -- ~13% (was solid 0xff363944)
  bg2 = 0x2e303a4a,          -- ~18% (was solid 0xff414550)

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
