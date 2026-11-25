-- Where the clock's time has to stop so macOS's screen-recording dot lands in
-- the pill instead of on the digits. Pure: the event's env and the bar's
-- geometry in, one label padding out. No sbar calls, so it runs headless.
local M = {}

-- The indicator WINDOW is 28pt, but the circle in it is about 10, centred, so
-- its left edge sits ~9pt into the window. The text ends 4pt short of the
-- circle: 5pt into the window.
M.INSET = 5

-- The ceiling. Whatever the event says, the pill never opens further than
-- this. The window starts at most 31pt in from a display's edge (22 on a
-- Sidecar), so a real hole is 26pt or less. An answer over the ceiling was
-- never this pill's dot (another display's coordinates, the pointer, a layout
-- that already went wrong) and is dropped, not clamped: 40pt opened for a dot
-- that is not there is still wrong.
M.MAX_HOLE = 40

-- Engines without RECORDING_FRAMES (0.3.0 and older) report one frame in desktop
-- coordinates, for whichever display's window the list returned first, and
-- can take the pointer for it. Only their on/off is believed: on makes the
-- room the dot needs on a MacBook's own display with the pill 8pt from the
-- edge (1504 - 1481 - 5).
M.LEGACY_HOLE = 18

-- "1:1481,3,28,28 2:1081,-6,28,28" -> { [1] = { x, y, w, h }, [2] = ... }
-- Whole points only, as the engine prints them; anything else is not an entry.
function M.parse(frames)
  local dots = {}
  for id, x, y, w, h in tostring(frames or ""):gmatch(
      "(%d+):(%-?%d+),(%-?%d+),(%d+),(%d+)") do
    -- A separate local: Lua 5.5 makes loop variables read-only.
    local display = math.tointeger(tonumber(id))
    if display then
      dots[display] = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) }
    end
  end
  return dots
end

-- The dot is drawn in the strip the native menu bar owns. Only a bar that
-- covers that strip wears it.
function M.covers_menu_bar(bar)
  return bar ~= nil and bar.topmost == "on" and (bar.position or "top") == "top"
end

-- The label.padding_right that takes every bar's dot into the pill.
--   env    the recording_change env table
--   rects  the pill's bounding_rects: ["display-N"] = { origin = {x, y},
--          size = {w, h} } in that display's BAR points
--   bar    sbar.query("bar"): topmost, position, margin, y_offset, height
--   rest   the padding with no recording
-- macOS draws the dot on every display and one item serves every display's
-- bar, so the largest hole any of them needs wins. Never under `rest`, never
-- over max(rest, MAX_HOLE). nil: the engine named displays but no bar has
-- laid the pill out yet; ask again shortly.
function M.padding(env, rects, bar, rest)
  rest = tonumber(rest) or 8
  env = env or {}
  if env.RECORDING ~= "on" or not M.covers_menu_bar(bar) then return rest end
  local ceiling = math.max(rest, M.MAX_HOLE)

  if env.RECORDING_FRAMES == nil then
    return math.min(math.max(rest, M.LEGACY_HOLE), ceiling)
  end

  if type(rects) ~= "table" or next(rects) == nil then return nil end
  -- RECORDING_FRAMES is in display points; bounding_rects are in bar points.
  -- The bar starts `margin` in from the display's left edge and `y_offset`
  -- down from its top.
  local margin = tonumber(bar.margin) or 0
  local top = tonumber(bar.y_offset) or 0
  local height = tonumber(bar.height) or 0
  local pad = rest
  for id, dot in pairs(M.parse(env.RECORDING_FRAMES)) do
    local rect = rects[string.format("display-%d", id)]
    local left = rect and rect.origin and tonumber(rect.origin[1])
    local width = rect and rect.size and tonumber(rect.size[1])
    local centre = dot.y + dot.h / 2
    if left and width and (height <= 0 or (centre >= top and centre <= top + height)) then
      -- How far left of the pill's right edge the indicator window starts.
      local reach = left + width - (dot.x - margin)
      if reach > 0 and reach <= M.MAX_HOLE + M.INSET then
        pad = math.max(pad, reach - M.INSET)
      end
    end
  end
  return math.min(pad, ceiling)
end

return M
