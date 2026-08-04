-- Circular spinner: the engine's built-in solid-arc image ("spinner", a
-- continuous round-capped ring) spun via image.rotation (rasterized per
-- 30° step, atlas-cached — 12 frames total).
-- attach(item, opts{size=13, align="r"}) -> { start = fn, stop = fn }.
local M = {}

function M.attach(item, opts)
  opts = opts or {}
  local size = opts.size or 13
  local align = opts.align or "r"
  local running = false
  local angle = 0

  local function tick()
    if not running then return end
    angle = (angle + 30) % 360
    item:set({ image = { rotation = angle } })
    sbar.delay(0.08, tick)
  end

  return {
    start = function()
      if running then return end
      running = true
      angle = 0
      item:set({ image = {
        string = "spinner",
        size = size,
        align = align,
        rotation = 0,
        drawing = true,
        padding_left = opts.padding_left or 5,
        padding_right = opts.padding_right or 0,
      } })
      tick()
    end,
    stop = function()
      if not running then return end
      running = false
      item:set({ image = { drawing = false } })
    end,
  }
end

return M
