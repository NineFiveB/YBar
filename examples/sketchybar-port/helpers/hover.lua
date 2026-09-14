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

-- Colour-only attach over a SET of targets: no gradient, no lift, and
-- crucially no write to y_offset AT ALL. Rows depend on that — a row sets
-- its own alignment offset in M.row, and an attach that touched y_offset
-- would overwrite it and make the selector hop as the pointer arrived.
--
-- Every watcher gets ONE closure that fades every target, and that is not a
-- style choice: the engine keeps a single handler per (item, event) pair and
-- a later subscribe silently replaces the earlier one. So a cell whose
-- plates light together must be wired here, in one call, rather than as
-- several attachColor calls naming the same watcher.
function M.attachColorAll(targets, watchers, base, hover)
  for _, w in ipairs(watchers) do
    w:subscribe("mouse.entered", function()
      for _, t in ipairs(targets) do M.fade(t, hover, M.ENTER_FRAMES) end
    end)
    w:subscribe("mouse.exited", function()
      for _, t in ipairs(targets) do M.fade(t, base, M.EXIT_FRAMES) end
    end)
  end
end

-- The single-target case.
function M.attachColor(target, watchers, base, hover)
  M.attachColorAll({ target }, watchers, base, hover)
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
local function plate(item, opts)
  item:set({
    background = {
      color = colors.transparent,
      height = opts.height or 22,
      corner_radius = opts.radius or 4,
      y_offset = opts.y_offset or -1,   -- positive is up
    },
  })
end

function M.row(item, opts)
  opts = opts or {}
  plate(item, opts)
  -- attachColor, NOT attach: an elevation path would clobber the y_offset
  -- plate() just set and make the selector hop on hover.
  M.attachColor(item, { item }, colors.transparent, opts.hover or colors.row_hover)
end

-- A multi-line cell: several rows stacked to read as ONE entry (a device
-- name over its connection status), so the whole cell lights as one. Each
-- row carries its own plate and every row drives all of them.
--
-- This exists instead of "M.row each line, then attachColor the sibling":
-- that pairing subscribes each row to mouse.entered twice, and the engine
-- keeps only the last handler per (item, event) — the sibling registration
-- replaced the row's own, so each line lit its neighbour instead of itself.
function M.rowGroup(items, opts)
  opts = opts or {}
  for _, item in ipairs(items) do plate(item, opts) end
  M.attachColorAll(items, items, colors.transparent, opts.hover or colors.row_hover)
end

return M
