-- Circular spinner: the engine's built-in solid-arc image ("spinner", a
-- continuous round-capped ring) spun via image.rotation (rasterized per
-- 12° step, atlas-cached — 30 frames total, ~25fps).
-- attach(item, opts{size=13, align="r"}) -> { start = fn, stop = fn }.
local M = {}

function M.attach(item, opts)
  opts = opts or {}
  local size = opts.size or 13
  local align = opts.align or "r"
  local running = false
  local angle = 0
  -- Refcount so overlapping round trips (wifi runs its interface probe and
  -- its scan at once) don't let the first to finish stop the spinner out
  -- from under the second: it hides only when the last start is matched.
  local depth = 0

  local function tick()
    if not running then return end
    angle = (angle + 12) % 360
    item:set({ image = { rotation = angle } })
    sbar.delay(0.04, tick)
  end

  return {
    start = function()
      depth = depth + 1
      if running then return end
      running = true
      angle = 0
      item:set({ image = {
        string = "spinner",
        size = size,
        align = align,
        rotation = 0,
        drawing = true,
        padding_left = opts.padding_left or 4,
        padding_right = opts.padding_right or 0,
      } })
      tick()
    end,
    stop = function()
      if depth > 0 then depth = depth - 1 end
      if depth > 0 or not running then return end
      running = false
      item:set({ image = { drawing = false } })
    end,
  }
end

return M
