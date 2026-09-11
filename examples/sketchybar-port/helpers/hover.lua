local colors = require("colors")

-- Hover feedback for the bar's pills and popup rows: the resting fill lifts
-- one tone while the pointer is over a pill, and settles back when it leaves.
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
-- immediate under the pointer and release gently, the opposite of a
-- symmetric fade.
--
-- Vendored from the Windows port's helpers/hover.lua, colour only. The
-- elevated variant there (attachRaised: bevel gradient + one-point lift)
-- needs colors.shade and neither theme here ships it, so it is not carried.
local M = {}

M.ENTER_FRAMES = 5  -- ~83ms
M.EXIT_FRAMES = 10  -- ~167ms

-- Fade `target`'s background COLOUR only, with no elevation. Popup rows use
-- this: they are flat list entries, and a row that lifted under the pointer
-- would make a dense list jitter as the eye moved down it.
function M.fade(target, color, frames)
  sbar.animate("sin", frames or M.ENTER_FRAMES, function()
    target:set({ background = { color = color } })
  end)
end

-- Colour-only attach: no gradient, no lift, and crucially no write to
-- y_offset AT ALL. Rows depend on that — a row sets its own alignment
-- offset in M.row, and an attach that touched y_offset would overwrite it
-- and make the selector hop as the pointer arrived.
function M.attachColor(target, watchers, base, hover)
  for _, w in ipairs(watchers) do
    w:subscribe("mouse.entered", function() M.fade(target, hover, M.ENTER_FRAMES) end)
    w:subscribe("mouse.exited", function() M.fade(target, base, M.EXIT_FRAMES) end)
  end
end

-- Drive `target`'s fill from the hover state of every item in `watchers`.
-- Colour only: this is what pills and popup rows both use. Returns nothing;
-- the subscriptions own themselves.
function M.attach(target, watchers, base, hover)
  M.attachColor(target, watchers, base, hover)
end

-- The common shape: a bracket carrying the fill around a single member.
-- Defaults are the resting pill tone lifting to the next one, bg1 -> bg2.
-- On the port theme those are opaque tones; on the glass theme they are
-- tints over the blurred backdrop — and they must stay tints, because the
-- engine places a glass backdrop under a pill only while its colour's alpha
-- is above 0.02, so an opaque hover fill would simply hide the material.
function M.pill(bracket, member, base, hover)
  M.attach(bracket, { bracket, member }, base or colors.bg1, hover or colors.bg2)
end

-- A popup row: no bracket, no resting fill, so the row supplies its own plate
-- and lifts it from transparent. Rows are the densest clickable surface in
-- the theme and the only one with no affordance at all otherwise — several
-- of them act on a click (join a network, connect a device, open an app).
--
-- The plate's height and radius are set once here rather than at each call
-- site: a row's own box is content-sized, so without an explicit height the
-- highlight would hug the glyphs instead of reading as a row.
-- y_offset is NOT cosmetic here. A row's plate centres on the item's BOX, but
-- a row's visible content does not sit centred in that box — the box includes
-- the label's descender room, so a plate centred on it rides low against the
-- icon and cap band the eye actually tracks. -1 (positive is up) is the
-- Windows port's measurement on its tray list at 2x: content centre 143.5
-- against a plate centre of 144.5 unadjusted.
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
  -- attachColor, NOT attach: an elevation path would clobber the y_offset
  -- set immediately above and make the selector hop on hover.
  M.attachColor(item, { item }, colors.transparent, opts.hover or colors.row_hover)
end

return M
