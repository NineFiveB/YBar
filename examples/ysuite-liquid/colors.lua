-- Liquid Glass mock palette from ysuite-web `.ybar-mac-*`.
-- Same keys as the port's colors.lua so every item file works unchanged.
return {
  black = 0x26000000,
  white = 0xffffffff,
  red = 0xffffffff,
  green = 0xffe4e4e4,
  blue = 0xffd2d2d2,
  yellow = 0xfff0f0f0,
  orange = 0xffe8e8e8,
  magenta = 0xffd8d8d8,
  grey = 0xff8e8e8e,
  connected = 0xff30d158,
  transparent = 0x00000000,
  -- Selection plates and gray capsules. Black wash and a low white, so they
  -- sit darker than a bright frost on the glass popup.
  selection = 0x50000000,
  button = 0x2cffffff,

  bar = {
    -- Unused by ysuite-liquid's bar.lua (the strip is fully clear). Kept so
    -- other item files can still read colors.bar.bg.
    bg = 0x00000000,
    border = 0x00000000,
  },
  popup = {
    bg = 0x212a2a2a,
    border = 0x2effffff,
  },
  -- Pills: keep alpha above ~0.02 so glass backdrops still attach, but light
  -- enough that inactive frost stays refractive instead of a solid plate.
  bg1 = 0x152a2a2a,
  bg2 = 0x28383838,
  row_hover = 0x16ffffff,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
