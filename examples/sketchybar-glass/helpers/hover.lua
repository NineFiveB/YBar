local colors = require("colors")

-- Fluent hover feedback for the bar's pills: the resting fill lifts one tone
-- while the pointer is over a pill, and settles back when it leaves.
--
-- Two engine details shape this, and neither is obvious from the Lua side.
--
-- 1. A pill is a bracket wrapping a member item, and the hit test returns the
--    BRACKET only for the padding between the member's content box and the
--    pill's edge — the member itself everywhere inside that. So a pointer
--    moving across one pill crosses a seam that fires mouse.exited on one and
--    mouse.entered on the other. Every participant therefore drives the SAME
--    target, or the fill flickers halfway through a hover.
--
-- 2. The daemon fires the old item's exit before the new item's enter, and an
--    in-flight animation retargets from its live value instead of restarting.
--    The exit/enter pair at that seam settles on the hover tone with no dip,
--    which is why 1 needs no extra bookkeeping.
--
-- Durations are frames at 60Hz. In fast, out slower: a highlight should feel
-- immediate under the pointer and release gently, which is the Windows 11
-- convention and the opposite of a symmetric fade.
local M = {}

M.ENTER_FRAMES = 5  -- ~83ms
M.EXIT_FRAMES = 10  -- ~167ms

-- ELEVATION (the pseudo-3D half of the hover).
--
-- The usual lift cue is a drop shadow, and it is the wrong one here twice
-- over. The strip is 0x0a0a0c, so a black shadow is very nearly invisible
-- against it; and scene_builder draws a shadow as a hard offset COPY of the
-- plate with no blur at all (scene_builder.cpp, "hard offset copy, no blur"),
-- so wherever it did show it would read as a 2007 hard-edged plate rather
-- than contact shadow.
--
-- On a dark UI depth is carried by LIGHT, not shade. A raised convex face
-- catches more light along its top than its bottom, so a hovered pill gains a
-- vertical gradient and rises a pixel. That is the whole trick, and it is
-- entirely free: no engine change, no new draw, no extra quad.
--
-- gradient_angle 90 puts `color` at the TOP edge and `gradient_color` at the
-- bottom. scene_builder sets gradientDir = (cos a, sin a) and the shader takes
-- t = dot(uv - 0.5, dir) + 0.5, so at 90 degrees t == uv.y, which is 0 at the
-- top. Getting this backwards inverts the light and the pill reads concave.
M.LIFT = 1      -- px the pill rises on hover; positive is up
M.BEVEL = 0.62  -- bottom tone as a fraction of the top: the face's curvature

-- The property set for one surface state. `raised` false is deliberately not
-- "omit the gradient": gradient_color lives behind a std::optional and, if it
-- has never been set, animates FROM transparent black — which flashes the
-- pill's lower half clear mid-fade. Writing equal stops at rest keeps the
-- gradient always present and always opaque, so only its colour ever moves.
local function paint(color, raised)
  return {
    background = {
      color = color,
      gradient_angle = 90,
      gradient_color = raised and colors.shade(color, M.BEVEL) or color,
      y_offset = raised and M.LIFT or 0,
    },
  }
end

-- Paint `target` as a resting flat pill or a raised lit one. frames <= 0 sets
-- directly, which is what the initial establish wants.
function M.surface(target, color, raised, frames)
  if not frames or frames <= 0 then
    target:set(paint(color, raised))
    return
  end
  sbar.animate("sin", frames, function() target:set(paint(color, raised)) end)
end

-- Fade `target`'s background COLOUR only, with no elevation. Popup rows use
-- this: they are flat list entries, and a row that lifted under the pointer
-- would make a dense list jitter as the eye moved down it.
function M.fade(target, color, frames)
  sbar.animate("sin", frames or M.ENTER_FRAMES, function()
    target:set({ background = { color = color } })
  end)
end

-- Colour-only counterpart to M.attach: no gradient, no lift, and crucially no
-- write to y_offset AT ALL.
--
-- Rows must use this. M.attach routes through M.surface, whose paint() sets
-- y_offset unconditionally (0 at rest, +LIFT raised), so a row that set its own
-- alignment offset and then attached had that offset overwritten with 0 on the
-- spot — and then shoved to +1 on every hover, so the selector jumped two
-- points as the pointer arrived and dropped back as it left.
function M.attachColor(target, watchers, base, hover)
  for _, w in ipairs(watchers) do
    w:subscribe("mouse.entered", function() M.fade(target, hover, M.ENTER_FRAMES) end)
    w:subscribe("mouse.exited", function() M.fade(target, base, M.EXIT_FRAMES) end)
  end
end

-- Elevated hover: fill + bevel gradient + one-point lift, driven through
-- M.surface. This is what the README's depth-hover GIF shows. NOT the shipped
-- behaviour -- the theme is Fluent-flat, so nothing calls it by default; swap
-- M.attach's body for a call to this to opt in.
function M.attachRaised(target, watchers, base, hover)
  M.surface(target, base, false, 0) -- establish the gradient stops up front
  for _, w in ipairs(watchers) do
    w:subscribe("mouse.entered", function() M.surface(target, hover, true, M.ENTER_FRAMES) end)
    w:subscribe("mouse.exited", function() M.surface(target, base, false, M.EXIT_FRAMES) end)
  end
end

-- Drive `target`'s fill from the hover state of every item in `watchers`.
-- Colour only: the shipped theme is flat, and this is what pills, the
-- calendar and popup rows all use. Returns nothing; the subscriptions own
-- themselves.
function M.attach(target, watchers, base, hover)
  M.attachColor(target, watchers, base, hover)
end

-- The common shape: a bracket carrying the fill around a single member.
-- Defaults are the Mica tint lifting to its hover tint: every pill that comes
-- through here is a glass pill (ybarrc.lua lights them by name), and over the
-- wallpaper material the fill is a tint, not a tone -- an opaque bg1 here
-- would simply hide the material it sits on.
function M.pill(bracket, member, base, hover)
  M.attach(bracket, { bracket, member }, base or colors.mica, hover or colors.mica_hover)
end

-- A popup row: no bracket, no resting fill, so the row supplies its own plate
-- and lifts it from transparent. Rows are the densest clickable surface in
-- the theme and the only one with no affordance at all otherwise — several
-- of them act on a click, and the tray's act destructively.
--
-- The plate's height and radius are set once here rather than at each call
-- site: a row's own box is content-sized, so without an explicit height the
-- highlight would hug the glyphs instead of reading as a row.
-- y_offset is NOT cosmetic here. A row's plate centres on the item's BOX, but
-- a row's visible content does not sit centred in that box — the box includes
-- the label's descender room, so a plate centred on it rides low against the
-- icon and cap band the eye actually tracks. Measured at 2x on the tray list:
-- content centre 143.5 (icon 128..159, cap band 137..151) against a plate
-- centre of 144.5 unadjusted.
function M.row(item, opts)
  opts = opts or {}
  item:set({
    background = {
      color = colors.transparent,
      height = opts.height or 22,
      corner_radius = opts.radius or 4,
      y_offset = opts.y_offset or -1,   -- positive is up
    },
  })
  -- attachColor, NOT attach: the elevation path would clobber the y_offset set
  -- immediately above and make the selector hop on hover.
  M.attachColor(item, { item }, colors.transparent, opts.hover or colors.row_hover)
end

return M
