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

return M
