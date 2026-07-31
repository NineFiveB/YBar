-- Liquid Glass palette: sonokai accents over translucent dark glass.
-- Same keys as the port's colors.lua so every item file works unchanged.
return {
  black = 0x26000000,        -- borders melt into soft shadow lines
  white = 0xffe2e2e3,
  red = 0xfffc5d7c,
  green = 0xff9ed072,
  blue = 0xff76cce0,
  yellow = 0xffe7c664,
  orange = 0xfff39660,
  magenta = 0xffb39df3,
  grey = 0xff9aa0ac,
  transparent = 0x00000000,

  bar = {
    bg = 0x00000000,         -- capsules float on nothing
    border = 0x00000000,
  },
  popup = {
    bg = 0x59161a24,         -- glass panel over popup blur
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
