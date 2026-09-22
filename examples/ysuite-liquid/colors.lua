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

  bar = {
    -- rgba(18, 18, 20, 0.25) — the mock's full-bleed strip.
    bg = 0x40121214,
    border = 0x00000000,
  },
  popup = {
    bg = 0x212a2a2a,
    border = 0x2effffff,
  },
  -- Pills: rgba(42,42,42,0.13). Hover: rgba(56,56,56,0.22).
  bg1 = 0x212a2a2a,
  bg2 = 0x38383838,
  row_hover = 0x16ffffff,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
