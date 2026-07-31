-- Liquid Glass palette: sonokai accents over translucent dark glass.
-- Same keys as the port's colors.lua so every item file works unchanged.
return {
  black = 0x26000000,        -- borders melt into soft shadow lines
  -- Apple system palette (dark mode): the accents macOS itself uses.
  white = 0xffffffff,
  red = 0xffff453a,          -- systemRed
  green = 0xff30d158,        -- systemGreen
  blue = 0xff0a84ff,         -- systemBlue
  yellow = 0xffffd60a,       -- systemYellow
  orange = 0xffff9f0a,       -- systemOrange
  magenta = 0xffbf5af2,      -- systemPurple
  grey = 0xff98989d,         -- systemGray
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
