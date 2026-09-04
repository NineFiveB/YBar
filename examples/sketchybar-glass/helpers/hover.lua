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

-- Fade `target`'s background to `color`. Exposed because pills whose colour
-- has more than one input (the workspace strip, where focus outranks hover)
-- have to compute the destination themselves.
function M.fade(target, color, frames)
  sbar.animate("sin", frames or M.ENTER_FRAMES, function()
    target:set({ background = { color = color } })
  end)
end

-- Drive `target`'s background from the hover state of every item in
-- `watchers`. Returns nothing; the subscriptions own themselves.
function M.attach(target, watchers, base, hover)
  for _, w in ipairs(watchers) do
    w:subscribe("mouse.entered", function() M.fade(target, hover, M.ENTER_FRAMES) end)
    w:subscribe("mouse.exited", function() M.fade(target, base, M.EXIT_FRAMES) end)
  end
end

-- The common shape: a bracket carrying the fill around a single member.
-- Defaults are the resting pill tone lifting to the raised-surface tone.
function M.pill(bracket, member, base, hover)
  M.attach(bracket, { bracket, member }, base or colors.bg1, hover or colors.bg2)
end

-- A popup row: no bracket, no resting fill, so the row supplies its own plate
-- and lifts it from transparent. Rows are the densest clickable surface in
-- the theme and the only one with no affordance at all otherwise — several
-- of them act on a click, and the tray's act destructively.
--
-- The plate's height and radius are set once here rather than at each call
-- site: a row's own box is content-sized, so without an explicit height the
-- highlight would hug the glyphs instead of reading as a row.
-- y_offset is NOT cosmetic here. A row's plate centres on the item's box, but
-- the content does not sit centred in it: the rows carry their own optical
-- nudges (the tray's icon is pushed down onto the label's centre line), so a
-- plate centred on the box reads high against the text it is meant to be
-- behind. Measured at 2x on the tray list: plate centre 141, text centre 146.
function M.row(item, opts)
  opts = opts or {}
  item:set({
    background = {
      color = colors.transparent,
      height = opts.height or 22,
      corner_radius = opts.radius or 4,
      y_offset = opts.y_offset or -2,   -- positive is up
    },
  })
  M.attach(item, { item }, colors.transparent, opts.hover or colors.row_hover)
end

return M
