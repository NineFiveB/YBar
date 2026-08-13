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
    bg = 0xf20b0b0d,         -- Fluent minimal: dark near-opaque flat strip
    border = 0x00000000,
  },
  popup = {
    bg = 0xf51c1c20,         -- solid dark panel (no backdrop blur behind it)
    border = 0x2effffff,
  },
  -- Fluent surfaces: subtle single-tone white fills over the dark strip —
  -- no glass rim, no backdrop; brightness alone separates rest/selected.
  bg1 = 0x17ffffff,          -- ~9% white: resting pill fill
  bg2 = 0x24ffffff,          -- ~14% white: raised/selected surface

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
