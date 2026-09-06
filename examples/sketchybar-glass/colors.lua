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
    -- Lifted off near-black (was 0x0a0a0c). Kept modest on purpose: the
    -- resting pill is bg1 at 0x1a1a1c, and the strip is what that pill is read
    -- against, so every step the strip takes upward is contrast the pills lose.
    bg = 0xfa121216,         -- ~98% opaque, one step off black
    border = 0x00000000,
  },
  popup = {
    -- A Mica panel: the plate is a tint over the wallpaper material, like the
    -- pills, but heavier -- a panel floats over whatever the wallpaper has
    -- there, and its text has to stay readable on the brightest patch of it.
    -- 80% #1c1c20 is Windows' own dark-Mica weight.
    bg = 0xcc1c1c20,
    border = 0x2effffff,
  },
  -- Pill surfaces are OPAQUE tones, not white overlays. Expressed as a
  -- percentage of white they took their lightness from whatever sat behind
  -- the strip, so a pill could only ever be LIGHTER than the bar; fixed tones
  -- let the pills sit darker than the strip, which is the intent here.
  bg1 = 0xff1a1a1c,          -- resting pill fill
  bg2 = 0xff26262a,          -- raised/selected surface, and the hover lift off bg1
  bg3 = 0xff32323a,          -- hover lift off bg2, for the pills that rest raised
  -- Mica pills (glass = true on Windows): the wallpaper material IS the
  -- surface and the fill is only its tint, so these carry alpha where the
  -- tones above deliberately do not. Windows' own dark Mica is #202020 at
  -- 80%; this sits at 60% so more of the wallpaper reads through the strip,
  -- and it is the one line to tune. The hover is the same tint two tones
  -- lighter: over the material a white overlay would wash the wallpaper out
  -- rather than lift the pill.
  mica = 0x99202020,
  mica_hover = 0x99343438,
  -- Popup rows rest transparent on the panel, so their hover IS an overlay.
  -- That is safe here in a way it is not on the bar, where the tones above
  -- are opaque precisely so a pill can sit darker than the strip.
  row_hover = 0x16ffffff,

  -- Scale a colour's RGB toward black (factor < 1) or white (factor > 1),
  -- preserving alpha. This is the hover bevel's only ingredient: a raised
  -- convex face catches more light at the top than at the bottom.
  shade = function(color, factor)
    local a = color & 0xff000000
    local r = math.min(255, math.floor(((color >> 16) & 0xff) * factor))
    local g = math.min(255, math.floor(((color >> 8) & 0xff) * factor))
    local b = math.min(255, math.floor((color & 0xff) * factor))
    return a | (r << 16) | (g << 8) | b
  end,

  with_alpha = function(color, alpha)
    if alpha > 1.0 or alpha < 0.0 then return color end
    return (color & 0x00ffffff) | (math.floor(alpha * 255.0) << 24)
  end,
}
