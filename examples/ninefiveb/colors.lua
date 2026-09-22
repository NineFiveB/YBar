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
  connected = 0xff30d158,    -- "Connected" status text/dot: the one chromatic
                             -- accent in the scheme (macOS system green)
  transparent = 0x00000000,

  bar = {
    -- 25% over the bar's own Liquid Glass, not the old 85% near-black. The
    -- strip now reads as the same material as the pills and popups, while
    -- still darkening whatever sits behind it — which is what keeps a pill
    -- (13%) distinct against it and near-white glyphs legible over a bright
    -- wallpaper. Drop this to 0x00000000 for a fully clear strip and raise
    -- bg1/bg2 to compensate, or the pills flatten into it.
    bg = 0x40121214,
    border = 0x00000000,
  },
  popup = {
    bg = 0x212a2a2a,         -- same tint as the pills: one material everywhere
    border = 0x2effffff,
  },
  -- True Tahoe glass is mostly backdrop: barely-there neutral tints, the
  -- blur and the specular rim carry the material.
  bg1 = 0x212a2a2a,          -- ~13%, luma-matched to the old blue-grey
  bg2 = 0x2e383838,          -- ~18%, and the hover lift off bg1 (still a
                             -- tint: the glass backdrop needs alpha > 0.02)
  -- Popup rows rest transparent on the panel, so their hover IS an overlay.
  row_hover = 0x16ffffff,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
