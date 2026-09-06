local settings = require("settings")
local colors = require("colors")

-- YBAR PORT: calendar popup rebuilt as a real month grid. Each day is its
-- own fixed-width cell item laid out by the popup flow layout
-- (popup.wrap_width — a ybar extension), so columns align exactly and
-- today gets a true gray rounded highlight instead of text brackets.
--
-- WINDOWS PORT: the EventKit "Upcoming" events list is dropped — there is
-- no cheap calendar-events API on Windows (the macOS build shelled out to
-- an AppleScript/EventKit helper). The popup keeps the month header + day
-- grid and gains an "Open Calendar" row that launches the system calendar
-- via `explorer.exe outlookcal:`. Right-click on the pill does the same.
-- The month grid itself is pure Lua (os.date/os.time) and is unchanged.

-- Padding item required because of bracket
sbar.add("item", { position = "right", width = settings.group_paddings })

local cell_w = 26
local grid_width = cell_w * 7   -- 7 columns
local max_cells = 42

local cal = sbar.add("item", "calendar", {
  -- Regular weight throughout: the native taskbar clock is not bold.
  -- Date and time share ONE family and size (Segoe UI, like the Windows
  -- clock): two faces at the same point size have different cap heights,
  -- and em-box centering then splits the baseline — the old Cascadia time
  -- needed a hand-tuned y_offset and still read misaligned.
  icon = {
    color = colors.white,
    padding_left = 7,
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = 11.5,
    },
  },
  label = {
    color = colors.white,
    padding_right = 7,
    font = {
      family = settings.font.text,
      style = settings.font.style_map["Regular"],
      size = 11.5,
    },
  },
  position = "right",
  -- 10 s so the minute rolls over promptly (the native taskbar clock updates
  -- on the minute); os.date is cheap. A time-zone change updates instantly via
  -- WM_TIMECHANGE regardless (the daemon re-reads the zone and refreshes).
  update_freq = 10,
  -- padding_left is one LESS than padding_right on purpose. This is the only
  -- pill painted by the ITEM's own background (its bracket is transparent),
  -- and it is the only one with a border — a border whose colour is 15% black
  -- over a near-black strip, i.e. invisible. So the edge the eye reads is the
  -- bg2 fill, one point INSIDE the box the geometry reports, and matching the
  -- gaps numerically left this one looking a point wider than the rest.
  -- Measured at 2x: 12px like every other gap here, 14px at 1, 16px at 2.
  padding_left = 0,
  padding_right = 1,
  background = {
    color = colors.mica, -- tint over the Mica material (glass set in ybarrc.lua)
    border_color = colors.black,
    border_width = 1
  },
  popup = { align = "right" }
})

local cal_bracket = sbar.add("bracket", "calendar.bracket", { cal.name }, {
  background = {
    color = colors.transparent,
    height = 26,
    border_color = colors.grey,
  },
  popup = { align = "right", wrap_width = grid_width }
})

-- The fill lives on the ITEM here, not the bracket (see the padding note
-- above), so the item is what carries the Mica tint and the glass flag
-- (ybarrc.lua names `calendar`, not its bracket) — but both the item and its
-- transparent bracket still have to drive the hover, because the bracket is
-- what the hit test returns over the pill's outer padding.
require("helpers.hover").attach(cal, { cal, cal_bracket }, colors.mica, colors.mica_hover)

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
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
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
      font = { size = 9, style = settings.font.style_map["Semibold"] },
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
      height = 19,
      corner_radius = 10,
    },
    label = {
      string = "",
      font = { size = 10.5 },
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

-- "Open Calendar" row replaces the macOS "Upcoming" events section
-- (events_header + event_rows + no_events on macOS — EventKit, dropped).
local open_calendar = sbar.add("item", "calendar.open", {
  position = "popup." .. cal_bracket.name,
  width = grid_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  icon = { drawing = false },
  label = {
    string = "Open Calendar",
    font = { size = 10.5, style = settings.font.style_map["Bold"] },
    color = colors.white,
    padding_left = 4,
  },
})

-- ── Rendering ──────────────────────────────────────────────────────────────
-- macOS took an `events` list here and bolded days that had events; with
-- the events feed dropped only today is bolded.
local update_calendar
update_calendar = function()
  local now = os.date("*t")

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
              style = settings.font.style_map[is_today and "Bold" or "Regular"],
            },
          },
        })
      end
    end
  end
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function hide_calendar_popup()
  cal_bracket:set({ popup = { drawing = false } })
end

local function open_system_calendar()
  -- Windows: system calendar deep link (was `open -a 'Calendar'` on macOS).
  sbar.exec("explorer.exe outlookcal:")
end

local function toggle_calendar_popup(env)
  if env.BUTTON == "right" then
    open_system_calendar()
    return
  end
  local should_draw = cal_bracket:query().popup.drawing == "off"
  if should_draw then
    update_calendar()
    cal_bracket:set({ popup = { drawing = true } })
  else
    hide_calendar_popup()
  end
end

open_calendar:subscribe("mouse.clicked", function()
  hide_calendar_popup()
  open_system_calendar()
end)

cal:subscribe("mouse.clicked", toggle_calendar_popup)
cal:subscribe("mouse.exited.global", hide_calendar_popup)

cal:subscribe({ "forced", "routine", "system_woke" }, function()
  -- Native menu bar clock format: "Mon Aug 3" + "7:50 PM" (no dots, day
  -- and hour without leading zeros). os.date's %a/%b/%I/%p all work in the
  -- Windows CRT strftime — same format strings as macOS.
  cal:set({
    icon = os.date("%a %b ") .. tostring(os.date("*t").day),
    label = (os.date("%I:%M %p"):gsub("^0", "", 1)),
  })
end)
