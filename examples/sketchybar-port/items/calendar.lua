local settings = require("settings")
local colors = require("colors")

-- Padding item required because of bracket
sbar.add("item", { position = "right", width = settings.group_paddings })

local popup_width = 320  -- Width for calendar grid with balanced padding
local max_events = 5      -- Increased events to fit below calendar

local cal = sbar.add("item", "calendar", {
  icon = {
    color = colors.white,
    padding_left = 8,
    font = {
      style = settings.font.style_map["Black"],
      size = 12.0,
    },
  },
  label = {
    color = colors.white,
    padding_right = 8,
    width = 75,
    align = "right",
    font = { family = settings.font.numbers },
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
  popup = { align = "right", height = 30 }
})

-- Double border for calendar using a single item bracket
local cal_bracket = sbar.add("bracket", "calendar.bracket", { cal.name }, {
  background = {
    color = colors.transparent,
    height = 30,
    border_color = colors.grey,
  },
  popup = { align = "right", height = 30 }
})

-- Padding item required because of bracket
sbar.add("item", { position = "right", width = settings.group_paddings })

-- Store calendar item references (created once at init, like battery widget)
local calendar_items = {}

-- Initialize calendar popup items ONCE (like battery widget does)
local function init_calendar_items()
  local bracket_name = cal_bracket.name or "calendar.bracket"
  
  -- Month header
  calendar_items.header = sbar.add("item", "calendar.header", {
    position = "popup." .. bracket_name,
    width = popup_width,
    align = "center",
    padding_left = 25,
    padding_right = 25,
    label = {
      font = {
        size = 15,
        style = settings.font.style_map["Bold"]
      },
      color = colors.white
    }
    -- No background - separator line not needed here
  })
  
  -- Day names row - must match week row alignment exactly
  calendar_items.daynames = sbar.add("item", "calendar.daynames", {
    position = "popup." .. bracket_name,
    width = popup_width,
    align = "left",
    padding_left = 25,
    padding_right = 25,
    label = {
      font = { size = 12, family = settings.font.numbers },
      color = colors.grey
    }
    -- No background - we'll use a separate separator item if needed
  })
  
  -- Week rows (6 weeks max) - one item per week
  for week = 1, 6 do
    calendar_items["week" .. week] = sbar.add("item", "calendar.week." .. week, {
      position = "popup." .. bracket_name,
      width = popup_width,
      align = "left",
      padding_left = 25,
      padding_right = 25,
      label = {
        font = { size = 12, family = settings.font.numbers },
        color = colors.white
      }
    })
  end
  
  -- Separator
  calendar_items.separator = sbar.add("item", "calendar.separator", {
    position = "popup." .. bracket_name,
    width = popup_width,
    align = "center",
    padding_left = 25,
    padding_right = 25,
    background = {
      height = 2,
      color = colors.grey,
      y_offset = -10
    }
  })
  
  -- Events header
  calendar_items.events_header = sbar.add("item", "calendar.events.header", {
    position = "popup." .. bracket_name,
    width = popup_width,
    align = "left",
    label = {
      font = { size = 13, style = settings.font.style_map["Bold"] },
      color = colors.grey,
      padding_left = 8,
    }
  })
  
  -- Event items (max_events) - icon = title (left), label = date/time (right)
  for i = 1, max_events do
    calendar_items["event" .. i] = sbar.add("item", "calendar.event." .. i, {
      position = "popup." .. bracket_name,
      width = popup_width,
      icon = {
        font = { size = 11 },
        color = colors.grey,
        width = popup_width / 2,
        align = "left",
        padding_left = 8,
      },
      label = {
        font = { size = 11, family = settings.font.numbers },
        color = colors.grey,
        width = popup_width / 2,
        align = "right",
        padding_right = 8,
      },
      padding_top = 2,
      padding_bottom = 2,
    })
  end
  
  -- No events message
  calendar_items.no_events = sbar.add("item", "calendar.noevents", {
    position = "popup." .. bracket_name,
    width = popup_width,
    align = "center",
    padding_left = 25,
    padding_right = 25,
    icon = { drawing = false },
    label = {
      font = { size = 11 },
      color = colors.grey,
    },
  })
end

-- Initialize calendar items once
init_calendar_items()

-- Helper function to get days in month
local function get_days_in_month(year, month)
  local days_in_month = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
  if month == 2 and ((year % 4 == 0 and year % 100 ~= 0) or (year % 400 == 0)) then
    return 29  -- Leap year
  end
  return days_in_month[month]
end

-- Helper function to get day of week (0=Sunday, 1=Monday, ..., 6=Saturday)
-- Uses os.date for reliable calculation
local function get_day_of_week(year, month, day)
  -- Create a complete time table with all required fields
  local time_table = {
    year = year,
    month = month,
    day = day,
    hour = 12,
    min = 0,
    sec = 0,
    isdst = false
  }
  local time_val = os.time(time_table)
  if not time_val then
    -- Fallback: use current date structure and modify
    local now = os.date("*t")
    now.year = year
    now.month = month
    now.day = day
    now.hour = 12
    now.min = 0
    now.sec = 0
    time_val = os.time(now)
  end
  local date_table = os.date("*t", time_val)
  -- os.date wday: 1=Sunday, 2=Monday, ..., 7=Saturday
  -- Convert to 0=Sunday, 1=Monday, ..., 6=Saturday
  return date_table.wday - 1
end

-- Function to parse AppleScript calendar output
local function parse_calendar_events(script_output)
  local events = {}
  if not script_output or script_output == "" then
    return events
  end
  
  -- Split by lines and parse each event
  for line in string.gmatch(script_output, "[^\r\n]+") do
    if line and line ~= "" then
      -- Format: "Title | Date | Time | Location"
      local title, date, time, location = line:match("([^|]+)|([^|]+)|([^|]+)|(.+)")
      if title then
        table.insert(events, {
          title = title:gsub("^%s+", ""):gsub("%s+$", ""),
          date = date and date:gsub("^%s+", ""):gsub("%s+$", "") or "",
          time = time and time:gsub("^%s+", ""):gsub("%s+$", "") or "",
          location = location and location:gsub("^%s+", ""):gsub("%s+$", "") or ""
        })
      end
    end
  end
  
  return events
end

-- Forward declaration so fetch_calendar_events can reference update_calendar_items
local update_calendar_items

-- Function to fetch calendar events using AppleScript
local function fetch_calendar_events()
  -- YBAR PORT: helpers live in the original sketchybar tree
  local config_dir = SKETCHYBAR_CONFIG
  if not config_dir then
    -- Fallback: try common locations
    local home = os.getenv("HOME")
    if home then
      config_dir = home .. "/.config/sketchybar"
    else
      -- Last resort: use current directory structure
      config_dir = "/Users/w2flv/.config/sketchybar"
    end
  end
  
  local script_path = config_dir .. "/helpers/calendar_events.sh"
  
  -- Execute the helper script
  sbar.exec(script_path, function(output)
    if output and output ~= "" and not output:match("Error") and not output:match("Connection invalid") then
      local events = parse_calendar_events(output)
      update_calendar_items(events)
    else
      -- Script failed; show empty state (no fallback to AppleScript which opens Calendar.app)
      update_calendar_items({})
    end
  end)
end

-- Function to update calendar items with new data (no creation/removal - just updates)
update_calendar_items = function(events)
  -- Get current date info
  local now = os.date("*t")
  local current_year = now.year
  local current_month = now.month
  local today_date_str = os.date("%Y-%m-%d")
  
  -- Create a map of dates with events
  local events_by_date = {}
  for _, event in ipairs(events) do
    if event.date and event.date ~= "" then
      if not events_by_date[event.date] then
        events_by_date[event.date] = {}
      end
      table.insert(events_by_date[event.date], event)
    end
  end
  
  -- Update month header
  local month_names = {"January", "February", "March", "April", "May", "June", 
                       "July", "August", "September", "October", "November", "December"}
  local month_header = month_names[current_month] .. " " .. current_year
  calendar_items.header:set({ label = { string = month_header } })
  
  -- Update day names - match date cell width (each date cell is 5 chars + 1 space separator)
  -- Use spaces to center each letter within the same 5-char cell as dates
  local day_names_text = " S    M    T    W    T    F     S"
  calendar_items.daynames:set({ label = { string = day_names_text } })
  
  -- Calculate first day of month and days in month
  -- Use direct os.date calculation for maximum reliability
  -- January 1, 2026 should be Thursday (day 4: 0=Sun, 1=Mon, 2=Tue, 3=Wed, 4=Thu, 5=Fri, 6=Sat)
  local first_day_time = os.time{year=current_year, month=current_month, day=1, hour=12, min=0, sec=0, isdst=false}
  if not first_day_time then
    -- Fallback: construct from current date
    local now = os.date("*t")
    now.year = current_year
    now.month = current_month
    now.day = 1
    now.hour = 12
    now.min = 0
    now.sec = 0
    now.isdst = false
    first_day_time = os.time(now)
  end
  local first_day_table = os.date("*t", first_day_time)
  -- os.date wday: 1=Sunday, 2=Monday, ..., 7=Saturday
  -- Convert to our system: 0=Sunday, 1=Monday, ..., 6=Saturday
  local first_day = first_day_table.wday - 1
  local days_in_month = get_days_in_month(current_year, current_month)
  
  -- Update week rows - all white, single label per row
  for week = 1, 6 do
    local week_item = calendar_items["week" .. week]
    if not week_item then break end

    local week_days = {}
    local has_days = false

    for day_of_week = 0, 6 do
      local cell_index = (week - 1) * 7 + day_of_week
      local day_num = cell_index - first_day + 1

      if day_num < 1 or day_num > days_in_month then
        table.insert(week_days, "     ")
      else
        has_days = true
        local date_str = string.format("%d-%02d-%02d", current_year, current_month, day_num)
        local day_str_raw = tostring(day_num)
        local day_str
        local is_today = (day_num == now.day)

        if is_today then
          -- Highlight today with brackets
          if #day_str_raw == 1 then
            day_str = " [" .. day_str_raw .. "] "
          else
            day_str = "[" .. day_str_raw .. "] "
          end
        elseif events_by_date[date_str] then
          if #day_str_raw == 1 then
            day_str = " {" .. day_str_raw .. "} "
          else
            day_str = "{" .. day_str_raw .. "} "
          end
        else
          if #day_str_raw == 1 then
            day_str = "  " .. day_str_raw .. "  "
          else
            day_str = " " .. day_str_raw .. "  "
          end
        end

        table.insert(week_days, day_str)
      end
    end

    if has_days then
      local week_text = table.concat(week_days, " ")
      week_item:set({
        icon = { drawing = false },
        label = { string = week_text, color = colors.white },
      })
    else
      week_item:set({ icon = { drawing = false }, label = { string = "" } })
    end
  end

  
  -- Update events section with dynamic visibility
  if #events > 0 then
    -- Show events section
    calendar_items.separator:set({ drawing = true })
    calendar_items.events_header:set({ 
      drawing = true,
      label = { string = "Upcoming:" } 
    })
    calendar_items.no_events:set({ drawing = false })
    
    -- Sort events
    table.sort(events, function(a, b)
      local date_a = (a.date or "") .. " " .. (a.time or "")
      local date_b = (b.date or "") .. " " .. (b.time or "")
      return date_a < date_b
    end)
    
    -- Update event items - show only what's needed
    for i = 1, max_events do
      local event_item = calendar_items["event" .. i]

      if i <= #events then
        local event = events[i]
        local is_today = event.date == today_date_str

        -- Format date
        local date_label = ""
        if event.date and event.date ~= "" then
          local year, month, day = event.date:match("(%d+)-(%d+)-(%d+)")
          if year and month and day then
            local month_short = {"Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
            local month_num = tonumber(month)
            if month_num and month_num >= 1 and month_num <= 12 then
              date_label = month_short[month_num] .. " " .. day
            end
          end
        end

        -- Format time
        local time_display = event.time ~= "" and event.time or ""
        if time_display ~= "" and date_label ~= "" then
          date_label = date_label .. " " .. time_display
        end

        -- Truncate title
        local title = event.title or ""
        if #title > 22 then
          title = title:sub(1, 19) .. "..."
        end

        local event_color = is_today and colors.red or colors.grey
        event_item:set({
          drawing = true,
          icon = {
            string = "• " .. title,
            color = event_color,
          },
          label = {
            string = date_label,
          },
        })
      else
        event_item:set({ drawing = false })
      end
    end
  else
    -- No events - hide entire events section to eliminate empty space
    calendar_items.separator:set({ drawing = false })
    calendar_items.events_header:set({ drawing = false })
    calendar_items.no_events:set({
      drawing = true,
      label = { string = "No upcoming events" }
    })
    -- Hide all event items
    for i = 1, max_events do
      calendar_items["event" .. i]:set({ drawing = false })
    end
  end
end

-- Function to hide calendar popup (simple like battery widget)
local function hide_calendar_popup()
  cal_bracket:set({ popup = { drawing = false } })
end

-- Function to toggle calendar popup
local function toggle_calendar_popup(env)
  if env.BUTTON == "right" then
    -- Right click opens Calendar app
    sbar.exec("open -a 'Calendar'")
    return
  end
  
  -- Check current popup state - simple approach like battery widget
  local should_draw = cal_bracket:query().popup.drawing == "off"
  
  if should_draw then
    -- Show popup first (like battery widget does)
    -- Items already exist and are updated in background, so no creation needed!
    cal_bracket:set({ popup = { drawing = true } })
    -- Just refresh events if needed (data is already there from background updates)
    fetch_calendar_events()
  else
    hide_calendar_popup()
  end
end

-- Subscribe to click events on the calendar item
cal:subscribe("mouse.clicked", toggle_calendar_popup)

-- Subscribe mouse.exited to the item, but it will be ignored during opening
cal:subscribe("mouse.exited.global", hide_calendar_popup)

-- Subscribe mouse.entered to cancel hide when mouse enters popup items
-- We'll add this to the first popup item when it's created

-- Update calendar display and refresh data in background
cal:subscribe({ "forced", "routine", "system_woke" }, function(env)
  cal:set({ icon = os.date("%a. %d %b."), label = os.date("%I:%M %p") })
  
  -- Fetch real events (updates calendar items in the callback)
  fetch_calendar_events()
  
  -- Also refresh popup if it's open
  if cal_bracket:query().popup.drawing == "on" then
    -- Popup is already open, data will be updated by fetch_calendar_events above
  end
end)
