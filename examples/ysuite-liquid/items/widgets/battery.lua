local colors = require("colors")
local settings = require("settings")
local rule = require("helpers.separator")

-- Liquid Glass battery popup matched to ysuite-web screenshots:
-- capsule pill; 420pt wrap popup; blue segment tabs; green bar history
-- (24h / 10d) with y-axis (engine) and x-axis labels; last-charged lines.

local popup_width = 420
local inset = 12
local plot_width = popup_width - 2 * inset - 36   -- room for engine y-axis strip
local tab_track = colors.with_alpha(0xff000000, 0.38)
local tab_active = 0xff0a84ff
local bar_green = 0xff32d74b
local history_script = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/battery_history.py"

-- The pill uses the system battery symbol (macOS 27 menu-bar glyph).
-- Right-side items are placed from the right edge.
local function battery_symbol(charge, charging)
  local pct = charge or 100
  if charging and pct < 100 then
    return "sf:battery.100percent.bolt"
  end
  local level = "0"
  if pct >= 88 then level = "100"
  elseif pct >= 63 then level = "75"
  elseif pct >= 38 then level = "50"
  elseif pct >= 13 then level = "25"
  end
  return "sf:battery." .. level .. "percent"
end

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  icon = {
    string = battery_symbol(100, false),
    font = { size = 17 },
    color = colors.white,
    padding_left = 8,
    padding_right = 8,
    -- The SF battery symbol's ink box sat one device pixel low against the
    -- Wi-Fi and Bluetooth glyphs (measured ink centre 40.5 against 39.5).
    y_offset = 0.5,
  },
  label = { drawing = false },
  background = { drawing = false, glass = false, sheen = false },
  padding_left = 2,
  padding_right = 2,
  update_freq = 300,
})

local battery_bracket = sbar.add("bracket", "widgets.battery.bracket", {
  battery.name,
}, {
  background = {
    color = colors.bg1,
    height = settings.pill_height,
    corner_radius = settings.pill_height / 2,
  },
  popup = {
    align = "center",
    horizontal = true,
    wrap_width = popup_width,
  },
})

require("helpers.hover").pill(battery_bracket, battery)

local popup_pos = "popup." .. battery_bracket.name
local inner = popup_width - 2 * inset

local header = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Battery",
    font = { size = 14, style = settings.font.style_map["Regular"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = "…",
    font = { size = 14, style = settings.font.style_map["Regular"] },
    color = colors.white,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = rule.background({ y_offset = -15 }),
})

local function add_detail(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      align = "left",
      string = title,
      -- Secondary text on this popup has to be a dimmed white, not the mid
      -- grey the dark themes use: the glass here is light enough that
      -- 0xff8e8e8e sits almost exactly on the backdrop.
      color = colors.with_alpha(colors.white, 0.72),
      font = { size = 12.0 },
      width = popup_width / 2,
      padding_left = inset,
    },
    label = {
      align = "right",
      string = "—",
      color = colors.white,
      font = { size = 12.0, style = settings.font.style_map["Regular"] },
      width = popup_width / 2,
      padding_right = inset,
    },
  })
end

local power_source   = add_detail("Power Source")
local remaining_time = add_detail("Time Remaining")
local condition      = add_detail("Condition")

sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = rule.background(),
})

-- Segmented control: two equal tabs on one wrap line (track + blue active).
local tab_w = (inner - 4) / 2
local range_24h = sbar.add("item", "widgets.battery.range.24h", {
  position = popup_pos,
  width = tab_w,
  align = "center",
  icon = {
    string = "Last 24 Hours",
    font = { size = 12, style = settings.font.style_map["Regular"] },
    color = colors.white,
  },
  label = { drawing = false },
  background = {
    height = 26,
    corner_radius = 7,
    color = tab_active,
    drawing = true,
    glass = false,
    sheen = false,
  },
  padding_left = inset,
})

local range_10d = sbar.add("item", "widgets.battery.range.10d", {
  position = popup_pos,
  width = tab_w,
  align = "center",
  icon = {
    string = "Last 10 Days",
    font = { size = 12, style = settings.font.style_map["Regular"] },
    color = colors.with_alpha(colors.white, 0.88),
  },
  label = { drawing = false },
  background = {
    height = 26,
    corner_radius = 7,
    color = tab_track,
    drawing = true,
    glass = false,
    sheen = false,
  },
  padding_right = inset,
})

local last_charged = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Last charged to —",
    color = colors.white,
    font = { size = 13, style = settings.font.style_map["Regular"] },
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

local last_when = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "—",
    color = colors.with_alpha(colors.white, 0.72),
    font = { size = 12 },
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

local chart_title = sbar.add("item", "widgets.battery.chart_title", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Battery Level",
    color = colors.white,
    font = { size = 13, style = settings.font.style_map["Regular"] },
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

-- Filled while the pointer is on a bar; a single space keeps the row's height
-- so the chart does not jump when the detail appears.
local chart_detail = sbar.add("item", "widgets.battery.chart_detail", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = " ",
    color = colors.with_alpha(colors.white, 0.85),
    font = { size = 12, style = settings.font.style_map["Regular"] },
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

local buckets_24h = 64
local buckets_10d = 10

local function add_history_graph(name, buckets, drawing, height)
  return sbar.add("graph", name, buckets, {
    position = popup_pos,
    drawing = drawing,
    graph = {
      color = bar_green,
      style = "bars",
      plot_width = plot_width,
      tick = "off",
    },
    background = {
      height = height or 84,
      color = { alpha = 0 },
      border_color = { alpha = 0 },
      drawing = true,
    },
    icon = { drawing = false },
    label = { drawing = false },
    padding_left = inset,
    padding_right = 0,
  })
end

local history_24h = add_history_graph("widgets.battery.history.24h", buckets_24h, true, 102)
local history_10d = add_history_graph("widgets.battery.history.10d", buckets_10d, false)
history_10d:set({ graph = { axis_max = 150, tick = "off" } })

-- X-axis under the plot (not the y-axis strip). 24h is eight clock labels.
-- 10d is one column per day: weekday letter, then the date on Sundays.
local x_labels_24h = { "12 A", "3", "6", "9", "12 P", "3", "6", "9" }
local x_axis = {}
local x_dates = {}
local day_cell = plot_width / 10
for i = 1, 10 do
  x_axis[i] = sbar.add("item", "widgets.battery.xaxis." .. i, {
    position = popup_pos,
    width = day_cell,
    align = "center",
    drawing = i <= 8,
    icon = {
      string = x_labels_24h[i] or "",
      color = colors.with_alpha(colors.white, 0.75),
      font = { size = 10 },
    },
    label = { drawing = false },
    padding_left = (i == 1) and inset or 0,
  })
  x_dates[i] = sbar.add("item", "widgets.battery.xdate." .. i, {
    position = popup_pos,
    width = day_cell,
    align = "left",
    drawing = false,
    icon = {
      string = "",
      color = colors.with_alpha(colors.white, 0.65),
      font = { size = 10 },
      padding_left = 1,
    },
    label = { drawing = false },
    padding_left = (i == 1) and inset or 0,
  })
end

-- ── State ──────────────────────────────────────────────────────────────────
local last_charge = nil
local on_ac = nil
local history_range = "24h"
-- Raw samples for the hover line. 24h percents are 0-100; flags are 0/1.
-- 10d values are energy percent-points (0-150).
local series_24h = {}
local charging_24h = {}
local series_10d = {}

local function set_chart_detail(text)
  chart_detail:set({ icon = { string = (text and text ~= "") and text or " " } })
end

local function hide_details()
  battery_bracket:set({ popup = { drawing = false } })
  set_chart_detail(nil)
end

local function popup_open()
  return battery_bracket:query().popup.drawing == "on"
end

local function apply_pill()
  local charge = last_charge or 100
  local charging = on_ac and charge < 100
  local color = colors.white
  if charge <= 20 and not on_ac then
    color = 0xffff453a
  end
  battery:set({
    icon = {
      string = battery_symbol(charge, charging),
      color = color,
    },
  })
end

local function format_remaining(h_mm)
  local h, m = h_mm:match("^(%d+):(%d+)$")
  if not h then return h_mm end
  h, m = tonumber(h), tonumber(m)
  if h == 0 then return string.format("%d min", m) end
  if m == 0 then return string.format("%d hr", h) end
  return string.format("%d hr %d min", h, m)
end

local function apply_popup_rows()
  header:set({ label = { string = last_charge and (last_charge .. "%") or "—" } })
  power_source:set({ label = on_ac == false and "Battery" or "Power Adapter" })
end

local function paint_tabs()
  local on_24 = history_range == "24h"
  range_24h:set({
    icon = { color = colors.white },
    background = { color = on_24 and tab_active or tab_track },
  })
  range_10d:set({
    icon = { color = colors.with_alpha(colors.white, 0.88) },
    background = { color = (not on_24) and tab_active or tab_track },
  })
end

local function weekday_axis()
  local letters, dates = {}, {}
  local week = { S = "S", ["0"] = "S", ["1"] = "M", ["2"] = "T", ["3"] = "W", ["4"] = "T", ["5"] = "F", ["6"] = "S" }
  local noon = os.date("*t")
  noon.hour, noon.min, noon.sec = 12, 0, 0
  local origin = os.time(noon)
  for ago = 9, 0, -1 do
    local t = origin - ago * 86400
    local w = os.date("%w", t)
    letters[#letters + 1] = week[w] or ""
    if w == "0" then
      dates[#dates + 1] = os.date("%b ", t) .. tonumber(os.date("%d", t))
    else
      dates[#dates + 1] = ""
    end
  end
  return letters, dates
end

local function paint_xaxis()
  local on_10 = history_range == "10d"
  local letters, dates = {}, {}
  if on_10 then letters, dates = weekday_axis() end
  local cell = on_10 and day_cell or (plot_width / 8)
  for i = 1, 10 do
    if on_10 or i <= 8 then
      x_axis[i]:set({
        drawing = true,
        width = cell,
        align = "center",
        icon = { string = on_10 and (letters[i] or "") or (x_labels_24h[i] or "") },
      })
    else
      x_axis[i]:set({ drawing = false, width = 0 })
    end
    x_dates[i]:set({
      drawing = on_10,
      width = on_10 and day_cell or 0,
      icon = { string = on_10 and (dates[i] or "") or "" },
    })
  end
end

local function paint_graphs()
  local on_24 = history_range == "24h"
  history_24h:set({ drawing = on_24 })
  history_10d:set({ drawing = not on_24 })
  chart_title:set({
    icon = { string = on_24 and "Battery Level" or "Energy Usage" },
  })
end

local function script_lines(out)
  local lines = {}
  for line in (out or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  return lines
end

local function integers_on(line)
  local values = {}
  for v in (line or ""):gmatch("%d+") do
    values[#values + 1] = tonumber(v)
  end
  return values
end

-- Bucket index is 0-based, oldest first. The label is the middle of the bucket.
local function bucket_clock(index, count, hours)
  local window = hours * 3600
  local mid = os.time() - window + ((index + 0.5) / count) * window
  local text = os.date("%I:%M %p", math.floor(mid))
  return (text:gsub("^0", ""))
end

local function energy_day(index)
  local noon = os.date("*t")
  noon.hour, noon.min, noon.sec = 12, 0, 0
  local ago = (buckets_10d - 1) - index
  local t = os.time(noon) - ago * 86400
  return string.format("%s, %s %d", os.date("%a", t), os.date("%b", t), tonumber(os.date("%d", t)))
end

local function on_graph_hover(env)
  local index = tonumber(env.INFO)
  if not index then
    set_chart_detail(nil)
    return
  end
  if env.NAME == history_24h.name and history_range == "24h" then
    local pct = series_24h[index + 1]
    if not pct then
      set_chart_detail(nil)
      return
    end
    local text = string.format("%s  ·  %d%%", bucket_clock(index, buckets_24h, 24), pct)
    if charging_24h[index + 1] == 1 then
      text = text .. "  ·  Charging"
    end
    set_chart_detail(text)
  elseif env.NAME == history_10d.name and history_range == "10d" then
    local used = series_10d[index + 1]
    if not used then
      set_chart_detail(nil)
      return
    end
    set_chart_detail(string.format("%s  ·  %d%%", energy_day(index), used))
  end
end

local function update_history()
  if history_range == "10d" then
    sbar.exec(
      "pmset -g log | python3 '" .. history_script:gsub("'", "'\\''") .. "' daily "
        .. buckets_10d .. " 2>/dev/null",
      function(out)
        local raw = integers_on(script_lines(out)[1])
        local values = {}
        for i, v in ipairs(raw) do
          values[i] = v / 150
        end
        if #values > 0 then
          series_10d = raw
          history_10d:push(values)
        end
      end)
  else
    sbar.exec(
      "pmset -g log | python3 '" .. history_script:gsub("'", "'\\''") .. "' "
        .. buckets_24h .. " 24 2>/dev/null",
      function(out)
        local lines = script_lines(out)
        local percents = integers_on(lines[1])
        local flags = integers_on(lines[2])
        local values = {}
        for i, v in ipairs(percents) do
          values[i] = v / 100
        end
        if #values > 0 then
          series_24h = percents
          history_24h:push(values)
          if #flags == #values then
            charging_24h = flags
            local parts = {}
            for i, flag in ipairs(flags) do
              parts[i] = flag == 1 and "1" or "0"
            end
            history_24h:set({ graph = { marks = table.concat(parts, " ") } })
          else
            charging_24h = {}
            history_24h:set({ graph = { marks = "off" } })
          end
        end
      end)
  end
  sbar.exec(
    "pmset -g log | python3 '" .. history_script:gsub("'", "'\\''") .. "' last 2>/dev/null",
    function(out)
      local pct, when = out:match("^(%d+)|([^\r\n]+)")
      if pct then
        last_charged:set({ icon = { string = "Last charged to " .. pct .. "%" } })
        last_when:set({ icon = { string = when } })
      else
        last_charged:set({ icon = { string = "Last charged to —" } })
        last_when:set({ icon = { string = "—" } })
      end
    end)
end

local function set_range(range)
  if history_range == range then return end
  history_range = range
  set_chart_detail(nil)
  paint_tabs()
  paint_graphs()
  paint_xaxis()
  update_history()
end

local function refresh_from_pmset()
  sbar.exec("pmset -g batt", function(batt_info)
    local found, _, charge = batt_info:find("(%d+)%%")
    if found then last_charge = tonumber(charge) end
    if batt_info:find("Battery Power") then
      on_ac = false
    elseif batt_info:find("AC Power") then
      on_ac = true
    end
    apply_pill()

    if popup_open() then
      apply_popup_rows()
      local found_time, _, remaining = batt_info:find(" (%d+:%d+) remaining")
      remaining_time:set({
        label = { string = found_time and format_remaining(remaining) or "No estimate" },
      })
    end
  end)
end

local function update_main(env)
  local sender = env and env.SENDER
  if sender == "battery_change" then
    last_charge = tonumber(env.INFO) or last_charge
    apply_pill()
    if popup_open() then apply_popup_rows() end
  elseif sender == "power_source_change" then
    on_ac = env.INFO == "AC"
    apply_pill()
    if popup_open() then apply_popup_rows() end
  else
    refresh_from_pmset()
  end
end

local function update_health()
  sbar.exec("system_profiler SPPowerDataType 2>/dev/null", function(info)
    local cond = info:match("Condition: ([^\n]+)")
    if cond then condition:set({ label = cond }) end
  end)
end

local function toggle_details()
  local should_draw = battery_bracket:query().popup.drawing == "off"
  if should_draw then
    battery_bracket:set({ popup = { drawing = true } })
    apply_popup_rows()
    paint_tabs()
    paint_graphs()
    paint_xaxis()
    refresh_from_pmset()
    update_health()
    update_history()
  else
    hide_details()
  end
end

range_24h:subscribe("mouse.clicked", function() set_range("24h") end)
range_10d:subscribe("mouse.clicked", function() set_range("10d") end)
history_24h:subscribe("graph.hovered", on_graph_hover)
history_10d:subscribe("graph.hovered", on_graph_hover)

battery:subscribe("mouse.clicked", toggle_details)
battery:subscribe("mouse.exited.global", hide_details)
battery:subscribe(
  { "routine", "battery_change", "power_source_change", "system_woke" },
  update_main
)

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = settings.group_paddings
})

-- Warm both history series so the first popup open already has bars.
history_range = "24h"
update_history()
history_range = "10d"
update_history()
history_range = "24h"
paint_tabs()
paint_graphs()
paint_xaxis()
