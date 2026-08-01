local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: battery popup in the macOS style used across the other
-- widgets: "Battery" header with the percentage on the right, then
-- Power Source / Time Remaining / Condition / Max Capacity rows and a
-- Settings footer. The pill shows only the icon (percentage lives in
-- the popup). Maintenance, charge limit, low power mode, and current
-- status are gone — and with them the `battery` CLI dependency.

local popup_width = 260
local inset = 12

local battery = sbar.add("item", "widgets.battery", {
  position = "right",
  icon = {
    font = {
      style = settings.font.style_map["Regular"],
      size = 19.0,
    },
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
  update_freq = 10,
  padding_left = 2,
  padding_right = 2,
})

local battery_bracket = sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 }
})

local popup_pos = "popup." .. battery_bracket.name

-- ── Header: "Battery" + percentage ─────────────────────────────────────────
local header = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Battery",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = "…",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    color = colors.white,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

local function add_detail(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      align = "left",
      string = title,
      color = colors.grey,
      font = { size = 12.0 },
      width = popup_width / 2,
      padding_left = inset + 6,
    },
    label = {
      align = "right",
      string = "—",
      color = colors.grey,
      font = { size = 12.0, style = settings.font.style_map["Semibold"] },
      width = popup_width / 2,
      padding_right = inset,
    },
  })
end

local power_source   = add_detail("Power Source")
local remaining_time = add_detail("Time Remaining")
local condition      = add_detail("Condition")
local max_capacity   = add_detail("Max Capacity")

-- ── Battery Level graph (last 24 hours, from pmset's charge log) ───────────
local history_script = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/battery_history.py"
local history_buckets = 216   -- 24h at ~6.7 min per sample; 1pt per sample

sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Battery Level",
    color = colors.white,
    font = { size = 13, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = "Last 24 Hours",
    color = colors.grey,
    font = { size = 11.0 },
    width = popup_width / 2,
    padding_right = inset,
  },
  padding_top = 6,
})

local history = sbar.add("graph", "widgets.battery.history", history_buckets, {
  position = popup_pos,
  graph = { color = colors.green },
  background = {
    height = 64,
    color = { alpha = 0 },
    border_color = { alpha = 0 },
    drawing = true,
  },
  icon = { drawing = false },
  label = { drawing = false },
  padding_left = inset,
  padding_right = inset,
})

local function update_history()
  sbar.exec(
    "pmset -g log | python3 '" .. history_script:gsub("'", "'\\''") .. "' "
      .. history_buckets .. " 2>/dev/null",
    function(out)
      local values = {}
      for v in out:gmatch("%d+") do
        values[#values + 1] = tonumber(v) / 100
      end
      if #values > 0 then history:push(values) end
    end)
end

sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local settings_row = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = icons.gear .. "  Settings",
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = popup_width - 20,
    padding_left = inset,
  },
  label = { drawing = false },
})

-- ── Updates ────────────────────────────────────────────────────────────────
local function hide_details()
  battery_bracket:set({ popup = { drawing = false } })
end

local function update_main_icon()
  sbar.exec("pmset -g batt", function(batt_info)
    local found, _, charge = batt_info:find("(%d+)%%")
    charge = found and tonumber(charge) or nil

    local is_charging = batt_info:find("charging") ~= nil
      and batt_info:find("Battery Power") == nil

    local icon, color
    if is_charging then
      icon, color = icons.battery.charging, colors.green
    elseif charge and charge > 80 then
      icon, color = icons.battery._100, colors.green
    elseif charge and charge > 60 then
      icon, color = icons.battery._75, colors.green
    elseif charge and charge > 40 then
      icon, color = icons.battery._50, colors.green
    elseif charge and charge > 20 then
      icon, color = icons.battery._25, colors.orange
    else
      icon, color = icons.battery._0, colors.red
    end

    battery:set({ icon = { string = icon, color = color } })

    if battery_bracket:query().popup.drawing == "on" then
      header:set({ label = { string = charge and (charge .. "%") or "—" } })
      power_source:set({
        label = batt_info:find("Battery Power") and "Battery" or "Power Adapter",
      })
      local found_time, _, remaining = batt_info:find(" (%d+:%d+) remaining")
      remaining_time:set({ label = found_time and remaining or "No estimate" })
    end
  end)
end

local function update_health()
  sbar.exec("system_profiler SPPowerDataType 2>/dev/null", function(info)
    local cond = info:match("Condition: ([^\n]+)")
    if cond then condition:set({ label = cond }) end
    local capacity = info:match("Maximum Capacity: (%d+)%%")
    if capacity then max_capacity:set({ label = capacity .. "%" }) end
  end)
end

local function toggle_details()
  local should_draw = battery_bracket:query().popup.drawing == "off"
  if should_draw then
    battery_bracket:set({ popup = { drawing = true } })
    update_main_icon()
    update_health()
    update_history()
  else
    hide_details()
  end
end

settings_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.Battery-Settings.extension'")
  hide_details()
end)

battery:subscribe("mouse.clicked", toggle_details)
battery:subscribe("mouse.exited.global", hide_details)
battery:subscribe({ "routine", "power_source_change", "system_woke" }, update_main_icon)

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = settings.group_paddings
})
