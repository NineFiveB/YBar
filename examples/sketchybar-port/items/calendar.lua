local settings = require("settings")
local colors = require("colors")
local rule = require("helpers.separator")
local hover = require("helpers.hover")

-- YBAR PORT: calendar popup rebuilt as a real month grid. Each day is its
-- own fixed-width cell item laid out by the popup flow layout
-- (popup.wrap_width — a ybar extension), so columns align exactly and
-- today gets a true gray rounded highlight instead of text brackets.

-- Padding item required because of bracket
sbar.add("item", { position = "right", width = settings.group_paddings })

local cell_w = 30
local grid_width = cell_w * 7   -- 7 columns
local max_events = 5
local max_cells = 42

local cal = sbar.add("item", "calendar", {
  -- Regular weight throughout: the native menu bar clock is not bold.
  icon = {
    color = colors.white,
    padding_left = 8,
    -- The icon part is ink-centered, so the correction depends on whether
    -- the string has a descender. "%a %b d" carries the "g" of "Aug", and
    -- including it in the centered box pushes the caps ABOVE the time's cap
    -- line (measured: cap-tops 26 vs 30 device px at +1; equal at -1).
    -- The glass themes show the weekday alone — no descender, nothing to
    -- correct, and the -1 just dropped "Fri" 2 device px below the clock.
    y_offset = YSUITE_LIQUID and 0 or -1,
    font = {
      style = settings.font.style_map["Regular"],
      size = 13.0,   -- same size as the time label
    },
  },
  label = {
    color = colors.white,
    padding_right = 8,
    font = { family = settings.font.numbers, style = settings.font.style_map["Regular"] },
  },
  position = "right",
  -- 10 s so the minute rolls over promptly (the native menu bar clock
  -- updates on the minute); os.date is cheap, and the tick sets only the
  -- two clock strings — the grid and the events feed belong to popup open.
  update_freq = 10,
  padding_left = 1,
  padding_right = 1,
  background = {
    color = colors.bg2,
    border_color = colors.black,
    border_width = 1
  },
  popup = { align = "right" }
})

local cal_bracket = sbar.add("bracket", "calendar.bracket", { cal.name }, {
  background = {
    color = colors.transparent,
    height = 30,
    border_color = colors.grey,
  },
  popup = { align = "right", wrap_width = grid_width }
})

-- Padding item required because of bracket
sbar.add("item", { position = "right", width = settings.group_paddings })

-- ── Popup construction (fixed pools, flow layout) ──────────────────────────
-- Header line: a back arrow, the month, a forward arrow. Three items rather
-- than one because a flow line is the only way to put the arrows on the
-- month's own baseline and still have them be their own hit targets — an
-- item has exactly two text slots, and both are spoken for by the month.
local function add_arrow(name, glyph)
  local arrow = sbar.add("item", name, {
    position = "popup." .. cal_bracket.name,
    width = cell_w,
    padding_left = 0,
    padding_right = 0,
    align = "center",
    icon = { drawing = false },
    label = {
      string = glyph,
      font = { size = 14, style = settings.font.style_map["Bold"] },
      color = colors.with_alpha(colors.white, 0.7),
    },
  })
  hover.row(arrow, { height = 22, radius = 6, flat = true })
  return arrow
end

local prev_month = add_arrow("calendar.prev", "‹")

local header = sbar.add("item", "calendar.header", {
  position = "popup." .. cal_bracket.name,
  width = grid_width - 2 * cell_w,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  icon = { drawing = false },
  label = {
    font = { size = 14, style = settings.font.style_map["Bold"] },
    color = colors.white,
  },
})
hover.row(header, { height = 22, radius = 6, flat = true })

local next_month = add_arrow("calendar.next", "›")

-- Day-name cells: one per column, centered over the date columns.
local daynames = { "S", "M", "T", "W", "T", "F", "S" }
for i = 1, 7 do
  sbar.add("item", "calendar.dn." .. i, {
    position = "popup." .. cal_bracket.name,
    width = cell_w,
    padding_left = 0,
    padding_right = 0,
    align = "center",
    icon = { drawing = false },
    label = {
      string = daynames[i],
      font = { size = 10, style = settings.font.style_map["Semibold"] },
      color = colors.grey,
    },
  })
end

-- Day cells: uniform invisible pill background so every grid line has the
-- same height; today's pill is tinted gray.
local cells = {}
for i = 1, max_cells do
  cells[i] = sbar.add("item", "calendar.cell." .. i, {
    position = "popup." .. cal_bracket.name,
    width = cell_w,
    padding_left = 0,
    padding_right = 0,
    align = "center",
    icon = { drawing = false },
    background = {
      drawing = true,
      color = colors.transparent,
      height = 22,
      corner_radius = 11,
    },
    label = {
      string = "",
      font = { size = 12 },
      color = colors.white,
    },
  })
end

local separator = sbar.add("item", "calendar.separator", {
  position = "popup." .. cal_bracket.name,
  width = grid_width,
  padding_left = 0,
  padding_right = 0,
  icon = { drawing = false },
  label = { drawing = false },
  background = rule.background(),
})

-- Reads out whichever day the pointer is on, and today's date when it is on
-- none. The grid is 42 identical cells, so without this a hovered day says
-- nothing about itself — the number is all the cell has room for.
local dayline = sbar.add("item", "calendar.dayline", {
  position = "popup." .. cal_bracket.name,
  width = grid_width,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  icon = { drawing = false },
  label = {
    string = " ",
    font = { size = 11, style = settings.font.style_map["Regular"] },
    color = colors.with_alpha(colors.white, 0.85),
  },
})

local events_header = sbar.add("item", "calendar.events.header", {
  position = "popup." .. cal_bracket.name,
  width = grid_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  icon = { drawing = false },
  label = {
    string = "Upcoming",
    font = { size = 12, style = settings.font.style_map["Bold"] },
    color = colors.white,
    padding_left = 4,
  },
})

local event_rows = {}
for i = 1, max_events do
  event_rows[i] = sbar.add("item", "calendar.event." .. i, {
    position = "popup." .. cal_bracket.name,
    width = grid_width,
    padding_left = 0,
    padding_right = 0,
    drawing = false,
    icon = {
      font = { size = 11 },
      color = colors.grey,
      width = grid_width * 0.55,
      align = "left",
      padding_left = 4,
    },
    label = {
      font = { size = 11 },
      color = colors.grey,
      width = grid_width * 0.45,
      align = "right",
      padding_right = 4,
    },
  })
end

local no_events = sbar.add("item", "calendar.noevents", {
  position = "popup." .. cal_bracket.name,
  width = grid_width,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  icon = { drawing = false },
  label = {
    string = "No upcoming events",
    font = { size = 11 },
    color = colors.grey,
  },
})

-- ── Events feed (AppleScript helper from the sketchybar tree) ──────────────
local function parse_calendar_events(script_output)
  local events = {}
  for line in string.gmatch(script_output or "", "[^\r\n]+") do
    local title, date, time, location = line:match("([^|]+)|([^|]+)|([^|]+)|(.+)")
    if title then
      table.insert(events, {
        title = title:gsub("^%s+", ""):gsub("%s+$", ""),
        date = date and date:gsub("^%s+", ""):gsub("%s+$", "") or "",
        time = time and time:gsub("^%s+", ""):gsub("%s+$", "") or "",
      })
    end
  end
  return events
end

local update_calendar

-- Months away from the current one. Paging keeps the last feed rather than
-- refetching: the helper answers with upcoming events only, so a month in the
-- past or far ahead would come back empty and blank the dots on the way back.
local month_offset = 0
local last_events = {}
-- Per cell, what update_calendar left behind: the day it shows, its date key
-- and the fill it rests at. The hover handlers are wired once at load and the
-- grid is repainted under them, so they cannot close over a day number.
local cell_day = {}
local cell_date = {}
local cell_rest = {}
local events_on = {}
local today_line = " "

local function fetch_calendar_events()
  local config_dir = SKETCHYBAR_CONFIG or (os.getenv("HOME") .. "/.config/sketchybar")
  local script_path = config_dir .. "/helpers/calendar_events.sh"
  sbar.exec(script_path, function(output)
    if output and output ~= "" and not output:match("Error")
      and not output:match("Connection invalid") then
      update_calendar(parse_calendar_events(output))
    else
      update_calendar({})
    end
  end)
end

-- ── Rendering ──────────────────────────────────────────────────────────────
update_calendar = function(events)
  last_events = events
  local now = os.date("*t")
  local today_date_str = os.date("%Y-%m-%d")
  -- os.time normalises a month of 0 or 13, so an offset needs no wrap logic.
  local view = os.date("*t", os.time({
    year = now.year, month = now.month + month_offset, day = 1, hour = 12 }))

  local events_by_date = {}
  events_on = {}
  for _, event in ipairs(events) do
    if event.date ~= "" then
      events_by_date[event.date] = true
      local day_list = events_on[event.date] or {}
      day_list[#day_list + 1] = event
      events_on[event.date] = day_list
    end
  end

  local month_names = { "January", "February", "March", "April", "May", "June",
                        "July", "August", "September", "October", "November", "December" }
  header:set({ label = { string = month_names[view.month] .. " " .. view.year } })

  local first_time = os.time({
    year = view.year, month = view.month, day = 1, hour = 12, isdst = false })
  local first_day = os.date("*t", first_time).wday - 1   -- 0 = Sunday column
  local days_in_month = os.date("*t", os.time({
    year = view.year, month = view.month + 1, day = 0, hour = 12 })).day

  -- Only as many full grid lines as the month needs.
  local used_cells = math.ceil((first_day + days_in_month) / 7) * 7

  for i = 1, max_cells do
    local cell = cells[i]
    if i > used_cells then
      cell_day[i], cell_date[i], cell_rest[i] = nil, nil, colors.transparent
      cell:set({ drawing = false })
    else
      local day = i - first_day
      if day < 1 or day > days_in_month then
        cell_day[i], cell_date[i], cell_rest[i] = nil, nil, colors.transparent
        cell:set({
          drawing = true,
          background = { color = colors.transparent },
          label = { string = "" },
        })
      else
        local date_str = string.format("%d-%02d-%02d", view.year, view.month, day)
        local is_today = date_str == today_date_str
        local rest = is_today and (YSUITE_LIQUID and colors.selection
          or colors.with_alpha(colors.grey, 0.55))
          or colors.transparent
        cell_day[i], cell_date[i], cell_rest[i] = day, date_str, rest
        cell:set({
          drawing = true,
          background = { color = rest },
          label = {
            string = tostring(day),
            -- colors.today lets a theme give today's number a real accent; the
            -- highlight underneath stays the plain selection wash, so the glass
            -- is never tinted.
            color = is_today and (colors.today or colors.white) or colors.white,
            font = {
              style = settings.font.style_map[
                (is_today or events_by_date[date_str]) and "Bold" or "Regular"],
            },
          },
        })
      end
    end
  end

  -- Events section.
  if #events > 0 then
    separator:set({ drawing = true })
    events_header:set({ drawing = true })
    no_events:set({ drawing = false })

    table.sort(events, function(a, b)
      return (a.date .. " " .. a.time) < (b.date .. " " .. b.time)
    end)

    local month_short = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
    for i = 1, max_events do
      local event = events[i]
      if event then
        local date_label = ""
        local _, month, day = event.date:match("(%d+)-(%d+)-(%d+)")
        if month then
          date_label = month_short[tonumber(month)] .. " " .. day
        end
        if event.time ~= "" then
          date_label = date_label .. " " .. event.time
        end
        local title = event.title
        if #title > 20 then title = title:sub(1, 17) .. "…" end
        event_rows[i]:set({
          drawing = true,
          icon = {
            string = "•  " .. title,
            color = event.date == today_date_str and colors.white or colors.grey,
          },
          label = { string = date_label },
        })
      else
        event_rows[i]:set({ drawing = false })
      end
    end
  else
    separator:set({ drawing = true })
    events_header:set({ drawing = false })
    no_events:set({ drawing = true })
    for i = 1, max_events do event_rows[i]:set({ drawing = false }) end
  end

  -- The readout rests on today no matter which month is on screen.
  today_line = os.date("%A, %B ") .. now.day
  local todays = events_on[today_date_str]
  if todays then
    today_line = today_line .. "  ·  " .. #todays
      .. (#todays == 1 and " event" or " events")
  end
  dayline:set({ label = { string = today_line } })
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function show_month(offset)
  month_offset = offset
  update_calendar(last_events)
end

-- Scroll anywhere on the grid or the header pages the month. Up is back, the
-- direction a scrolled list moves toward its start.
local function page_scroll(env)
  local delta = tonumber(env.SCROLL_DELTA) or 0
  if delta == 0 then return end
  show_month(month_offset + (delta > 0 and -1 or 1))
end

prev_month:subscribe("mouse.clicked", function() show_month(month_offset - 1) end)
next_month:subscribe("mouse.clicked", function() show_month(month_offset + 1) end)
-- The month name is the way back: paging away is cheap, finding today again
-- should not mean counting clicks in the other direction.
header:subscribe("mouse.clicked", function() show_month(0) end)
for _, item in ipairs({ prev_month, header, next_month }) do
  item:subscribe("mouse.scrolled", page_scroll)
end

-- The hover wash has to belong to the same family as today's marker, or the
-- pointer reads louder than the date it is pointing at: the glass theme marks
-- today by darkening the glass, so hovering darkens it less.
local cell_hover = YSUITE_LIQUID
  and colors.with_alpha(0xff000000, 0.16)
  or colors.row_hover

-- What a hovered cell says about itself: its full date, and the first event on
-- it when the feed reaches that far.
local function day_summary(index)
  local date_str = cell_date[index]
  if not date_str then return today_line end
  local y, m, d = date_str:match("(%d+)-(%d+)-(%d+)")
  local when = os.time({
    year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
  local text = os.date("%A, %B ", when) .. tonumber(d)
  local list = events_on[date_str]
  if list then
    local first = list[1]
    text = text .. "  ·  "
      .. (first.time ~= "" and (first.time .. "  ") or "") .. first.title
    if #list > 1 then text = text .. "  +" .. (#list - 1) end
  end
  return text
end

-- Wired once, over a grid that is repainted underneath: the handlers read the
-- per-cell tables rather than closing over a day number, which would go stale
-- the first time the month changed.
for i = 1, max_cells do
  local cell = cells[i]
  cell:subscribe("mouse.entered", function()
    if not cell_day[i] then return end
    dayline:set({ label = { string = day_summary(i) } })
    -- Today already carries a fill; lifting it would fight the accent.
    if cell_rest[i] == colors.transparent then
      hover.fade(cell, cell_hover, hover.ENTER_FRAMES)
    end
  end)
  cell:subscribe("mouse.exited", function()
    dayline:set({ label = { string = today_line } })
    if cell_rest[i] == colors.transparent then
      hover.fade(cell, colors.transparent, hover.EXIT_FRAMES)
    end
  end)
  cell:subscribe("mouse.scrolled", page_scroll)
end

local function hide_calendar_popup()
  cal_bracket:set({ popup = { drawing = false } })
end

local function toggle_calendar_popup(env)
  if env.BUTTON == "right" then
    sbar.exec("open -a 'Calendar'")
    return
  end
  local should_draw = cal_bracket:query().popup.drawing == "off"
  if should_draw then
    month_offset = 0
    update_calendar(last_events)
    cal_bracket:set({ popup = { drawing = true } })
    fetch_calendar_events()
  else
    hide_calendar_popup()
  end
end

cal:subscribe("mouse.clicked", toggle_calendar_popup)
cal:subscribe("mouse.exited.global", hide_calendar_popup)

-- Clock only. The events feed spawns the EventKit helper and repaints all
-- 42 cells, so it runs when the popup opens (toggle_calendar_popup), not
-- on every tick of a popup nobody is looking at.
cal:subscribe({ "forced", "routine", "system_woke" }, function()
  -- Native menu bar clock format: "Mon Aug 3" + "7:50 PM" (no dots, day
  -- and hour without leading zeros).
  cal:set({
    icon = os.date(YSUITE_LIQUID and "%a" or "%a %b ") .. (YSUITE_LIQUID and "" or tostring(os.date("*t").day)),
    label = (os.date("%I:%M %p"):gsub("^0", "", 1)),
  })
end)

-- Paint the grid once at load. The dates and today's marker need nothing but
-- os.date, while only the event dots need the EventKit helper — and the grid
-- used to be filled solely by toggle_calendar_popup, so a popup opened any
-- other way (a script, a recording) showed an empty month.
update_calendar({})
