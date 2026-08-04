local settings = require("settings")
local colors = require("colors")

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
    font = {
      style = settings.font.style_map["Regular"],
      size = 12.0,
    },
  },
  label = {
    color = colors.white,
    padding_right = 8,
    width = 75,
    align = "right",
    font = { family = settings.font.numbers, style = settings.font.style_map["Regular"] },
  },
  position = "right",
  update_freq = 30,
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
local header = sbar.add("item", "calendar.header", {
  position = "popup." .. cal_bracket.name,
  width = grid_width,
  padding_left = 0,
  padding_right = 0,
  align = "center",
  icon = { drawing = false },
  label = {
    font = { size = 14, style = settings.font.style_map["Bold"] },
    color = colors.white,
  },
})

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
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
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
  local now = os.date("*t")
  local today_date_str = os.date("%Y-%m-%d")

  local events_by_date = {}
  for _, event in ipairs(events) do
    if event.date ~= "" then events_by_date[event.date] = true end
  end

  local month_names = { "January", "February", "March", "April", "May", "June",
                        "July", "August", "September", "October", "November", "December" }
  header:set({ label = { string = month_names[now.month] .. " " .. now.year } })

  local first_time = os.time({
    year = now.year, month = now.month, day = 1, hour = 12, isdst = false })
  local first_day = os.date("*t", first_time).wday - 1   -- 0 = Sunday column
  local days_in_month = os.date("*t", os.time({
    year = now.year, month = now.month + 1, day = 0, hour = 12 })).day

  -- Only as many full grid lines as the month needs.
  local used_cells = math.ceil((first_day + days_in_month) / 7) * 7

  for i = 1, max_cells do
    local cell = cells[i]
    if i > used_cells then
      cell:set({ drawing = false })
    else
      local day = i - first_day
      if day < 1 or day > days_in_month then
        cell:set({
          drawing = true,
          background = { color = colors.transparent },
          label = { string = "" },
        })
      else
        local date_str = string.format("%d-%02d-%02d", now.year, now.month, day)
        local is_today = day == now.day
        cell:set({
          drawing = true,
          background = {
            color = is_today and colors.with_alpha(colors.grey, 0.55)
              or colors.transparent,
          },
          label = {
            string = tostring(day),
            color = colors.white,
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
end

-- ── Interactions ───────────────────────────────────────────────────────────
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
    update_calendar({})
    cal_bracket:set({ popup = { drawing = true } })
    fetch_calendar_events()
  else
    hide_calendar_popup()
  end
end

cal:subscribe("mouse.clicked", toggle_calendar_popup)
cal:subscribe("mouse.exited.global", hide_calendar_popup)

cal:subscribe({ "forced", "routine", "system_woke" }, function()
  cal:set({ icon = os.date("%a. %d %b."), label = os.date("%I:%M %p") })
  fetch_calendar_events()
end)
