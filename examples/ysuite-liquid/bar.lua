local colors = require("colors")

-- Flush with the tiling. AeroSpace decides where a tiled window's edge lands
-- with its outer gaps, so read them rather than guess: change them there and
-- the bar follows. `aerospace config --get` only exposes mode bindings, so
-- the config file is the source.
local function outer_gap(side, fallback)
  local path = os.getenv("HOME") .. "/.aerospace.toml"
  local f = io.open(path, "r")
  if not f then return fallback end
  local value
  for line in f:lines() do
    local n = line:match("^%s*outer%." .. side .. "%s*=%s*(%d+)")
    if n then value = tonumber(n) end
  end
  f:close()
  return value or fallback
end

-- Bar padding is not the visible inset: the pills carry their own, and the
-- two ends differ because the right one also holds the clock's trailing
-- spacer. Measured on this theme — padding_left 9 puts the capsule at 8pt,
-- and padding_right 0 already lands at 8pt, so the right only needs padding
-- once the gap exceeds that floor.
local LEFT_BIAS = 1
local RIGHT_FLOOR = 8
local PAD_LEFT = outer_gap("left", 8) + LEFT_BIAS
local PAD_RIGHT = math.max(0, outer_gap("right", 8) - RIGHT_FLOOR)

local B = require("helpers.tunable")({
  { key = "bar.height", type = "number", default = 40, min = 24, max = 80,
    label = "Bar height", section = "Bar" },
}).bar

sbar.bar({
  height = B.height,
  -- No full-bleed material: a bar-wide NSGlassEffectView frosts the strip.
  -- Pills keep their own glass. The strip itself stays clear.
  color = colors.transparent,
  glass = false,
  fullscreen_show = true,
  -- Full-bleed strip, matching the webpage mock. A window inset would leak
  -- the native menu bar under topmost=on.
  margin = 0,
  y_offset = 0,
  corner_radius = 0,
  topmost = "on",
  padding_left = PAD_LEFT,
  padding_right = PAD_RIGHT,
})
