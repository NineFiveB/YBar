local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local shell = require("helpers.shell")

-- YBAR PORT: revised as a native-style Bluetooth menu with searching and
-- pairing. My Devices (paired, click to connect/disconnect, battery via the
-- sketchybar bluetooth_battery.sh helper), on-demand inquiry for nearby
-- discoverable devices (click to pair + connect), power handling, and a
-- Settings row. All rows come from fixed pools so ordering is stable.
-- Requires blueutil; the daemon needs Bluetooth access (Privacy & Security).

local popup_width = 350
local max_devices = 8

local bt_script = SKETCHYBAR_CONFIG .. "/helpers/bluetooth_battery.sh"

local blueutil_path = "/opt/homebrew/bin/blueutil"
if os.execute("test -x /opt/homebrew/bin/blueutil") == nil then
  blueutil_path = "/usr/local/bin/blueutil"
end
local function blueutil(args)
  return blueutil_path .. " " .. args
end

-- ── SF Symbols for device types ─────────────────────────────────────────────
local type_icons = {
  headset  = "􀑈",
  keyboard = "􀇳",
  trackpad = "􀟀",
  phone    = "􀟜",
  speaker  = "􀝎",
  generic  = icons.bluetooth,
}

local function battery_icon_for(pct)
  if pct >= 75 then return icons.battery._100
  elseif pct >= 50 then return icons.battery._75
  elseif pct >= 25 then return icons.battery._50
  elseif pct >= 10 then return icons.battery._25
  else return icons.battery._0
  end
end

local function battery_color_for(pct)
  if pct >= 50 then return colors.green
  elseif pct >= 20 then return colors.yellow
  else return colors.red
  end
end

-- ── Bar item: small bluetooth icon ──────────────────────────────────────────
local bt_icon = sbar.add("item", "widgets.bluetooth", {
  position = "right",
  icon = {
    string = icons.bluetooth,
    font = { style = settings.font.style_map["Regular"], size = 16.0 },
    color = colors.blue,
    width = 32,
    align = "center",
  },
  label = { drawing = false },
  padding_left = 4,
  padding_right = 4,
})

local bt_bracket = sbar.add("bracket", "widgets.bluetooth.bracket", { bt_icon.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 },
})

sbar.add("item", "widgets.bluetooth.padding", {
  position = "right",
  width = settings.group_paddings,
})

local popup_pos = "popup." .. bt_bracket.name

-- ── Popup header (spinner lives in the right slot while busy) ───────────────
local header = sbar.add("item", "widgets.bluetooth.popup.header", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "Bluetooth",
    align = "left",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = 10,
  },
  label = {
    string = "",
    align = "right",
    color = colors.grey,
    width = popup_width / 2,
    padding_right = 10,
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
  padding_bottom = 4,
})

-- Shown instead of device rows when the radio is off (click turns it on).
local power_row = sbar.add("item", "widgets.bluetooth.power", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    string = "Bluetooth is Off",
    align = "left",
    color = colors.grey,
    font = { size = 12.0 },
    width = popup_width / 2,
    padding_left = 10,
  },
  label = {
    string = "Turn On",
    align = "right",
    color = colors.white,
    font = { size = 12.0, style = settings.font.style_map["Semibold"] },
    width = popup_width / 2,
    padding_right = 10,
  },
})

-- Fixed pools: paired devices, then (after a separator) nearby devices.
local function add_device_row(name)
  return sbar.add("item", name, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    icon = {
      string = "",
      color = colors.grey,
      font = { size = 12.0 },
      width = popup_width - 110,
      align = "left",
      padding_left = 10,
    },
    label = {
      string = "",
      color = colors.grey,
      font = { size = 11.0, style = settings.font.style_map["Semibold"] },
      width = 100,
      align = "right",
      padding_right = 10,
    },
  })
end

local paired_rows = {}
for i = 1, max_devices do
  paired_rows[i] = add_device_row("widgets.bluetooth.dev." .. i)
end

sbar.add("item", "widgets.bluetooth.sep1", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local search_row = sbar.add("item", "widgets.bluetooth.search", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = icons.bluetooth .. "  Search for Devices…",
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = popup_width - 110,
    padding_left = 10,
  },
  label = {
    string = "",
    align = "right",
    color = colors.grey,
    font = { size = 11.0 },
    width = 100,
    padding_right = 10,
  },
})

local nearby_rows = {}
for i = 1, max_devices do
  nearby_rows[i] = add_device_row("widgets.bluetooth.near." .. i)
end

sbar.add("item", "widgets.bluetooth.sep2", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local settings_row = sbar.add("item", "widgets.bluetooth.settings", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = icons.gear .. "  Bluetooth Settings…",
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = popup_width - 20,
    padding_left = 10,
  },
  label = { drawing = false },
})

-- ── Spinner (shared by search and pairing) ──────────────────────────────────
local busy = false
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 0

local function spin()
  if not busy then
    header:set({ label = { string = "" } })
    return
  end
  spinner_index = spinner_index % #spinner_frames + 1
  header:set({ label = { string = spinner_frames[spinner_index] } })
  sbar.delay(0.1, spin)
end

local function set_busy(value)
  if busy == value then return end
  busy = value
  if busy then spin() end
end

-- ── Paired devices ──────────────────────────────────────────────────────────
local paired_cache = {}   -- { name, address, connected, battery, dtype }
-- blueutil aborts (exit 134, error on stderr) when the daemon lacks
-- Bluetooth permission — distinguish that from the radio being off.
local access_denied = false

local function populate_paired()
  for i, row in ipairs(paired_rows) do
    local dev = paired_cache[i]
    if dev then
      local label_str, label_color
      if dev.connected then
        if dev.battery >= 0 then
          label_str = battery_icon_for(dev.battery) .. " " .. dev.battery .. "%"
          label_color = battery_color_for(dev.battery)
        else
          label_str = "Connected"
          label_color = colors.white
        end
      else
        label_str = "Not Connected"
        label_color = colors.grey
      end
      row:set({
        drawing = true,
        icon = {
          string = (type_icons[dev.dtype] or type_icons.generic) .. "  " .. dev.name,
          color = dev.connected and colors.white or colors.grey,
        },
        label = { string = label_str, color = label_color },
      })
    else
      row:set({ drawing = false })
    end
  end
end

local function refresh_paired()
  sbar.exec(blueutil("--power") .. " 2>&1", function(power)
    local state = power:match("^%s*([01])%s*$")
    access_denied = state == nil
    if access_denied then
      power_row:set({
        drawing = true,
        icon = { string = "Bluetooth access needed" },
        label = { string = "Open Privacy…" },
      })
      paired_cache = {}
      populate_paired()
      return
    end
    local on = state == "1"
    power_row:set({
      drawing = not on,
      icon = { string = "Bluetooth is Off" },
      label = { string = "Turn On" },
    })
    if not on then
      paired_cache = {}
      populate_paired()
      return
    end
    sbar.exec("'" .. bt_script:gsub("'", "'\\''") .. "' 2>/dev/null", function(output)
      paired_cache = {}
      for line in string.gmatch(output or "", "[^\n]+") do
        local name, address, connected_str, battery_str, dtype =
          line:match("^([^|]*)|([^|]*)|([01])|([^|]*)|([^|]*)$")
        if name and address and #paired_cache < max_devices then
          paired_cache[#paired_cache + 1] = {
            name = name,
            address = address,
            connected = connected_str == "1",
            battery = tonumber(battery_str) or -1,
            dtype = dtype or "generic",
          }
        end
      end
      populate_paired()
    end)
  end)
end

for i, row in ipairs(paired_rows) do
  row:subscribe("mouse.clicked", function()
    local dev = paired_cache[i]
    if not dev then return end
    row:set({ label = { string = "…", color = colors.grey } })
    local action = dev.connected and "--disconnect" or "--connect"
    sbar.exec(blueutil(action .. " " .. shell.quote(dev.address)) .. " 2>/dev/null",
      function() sbar.delay(1, refresh_paired) end)
  end)
end

power_row:subscribe("mouse.clicked", function()
  if access_denied then
    sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth'")
    collapse_popup()
    return
  end
  power_row:set({ label = { string = "…" } })
  sbar.exec(blueutil("--power 1") .. " 2>/dev/null", function()
    power_row:set({ label = { string = "Turn On" } })
    sbar.delay(1, refresh_paired)
  end)
end)

-- ── Nearby devices: inquiry + pairing ───────────────────────────────────────
local nearby_cache = {}   -- { name, address }

local function populate_nearby(status)
  search_row:set({ label = { string = status or "" } })
  for i, row in ipairs(nearby_rows) do
    local dev = nearby_cache[i]
    if dev then
      row:set({
        drawing = true,
        icon = { string = type_icons.generic .. "  " .. dev.name, color = colors.white },
        label = { string = "Pair", color = colors.grey },
      })
    else
      row:set({ drawing = false })
    end
  end
end

local function run_inquiry()
  if busy then return end
  if access_denied then
    populate_nearby("No Bluetooth access")
    return
  end
  set_busy(true)
  search_row:set({ label = { string = "" } })
  sbar.exec(blueutil("--inquiry 8") .. " 2>/dev/null", function(output)
    set_busy(false)
    local paired_addrs = {}
    for _, dev in ipairs(paired_cache) do paired_addrs[dev.address:lower()] = true end
    nearby_cache = {}
    local seen = {}
    for line in string.gmatch(output or "", "[^\n]+") do
      local address = line:match("address: ([%x%-:]+)")
      if address and not seen[address:lower()]
        and not paired_addrs[address:lower()]
        and #nearby_cache < max_devices
      then
        seen[address:lower()] = true
        local name = line:match('name: "([^"]*)"')
        nearby_cache[#nearby_cache + 1] = {
          name = (name and name ~= "") and name or address,
          address = address,
        }
      end
    end
    populate_nearby(#nearby_cache == 0 and "No devices found" or "")
  end)
end

search_row:subscribe("mouse.clicked", run_inquiry)

for i, row in ipairs(nearby_rows) do
  row:subscribe("mouse.clicked", function()
    local dev = nearby_cache[i]
    if not dev or busy then return end
    set_busy(true)
    row:set({ label = { string = "Pairing…", color = colors.white } })
    sbar.exec(
      blueutil("--pair " .. shell.quote(dev.address)) .. " >/dev/null 2>&1 && "
        .. blueutil("--connect " .. shell.quote(dev.address)) .. " >/dev/null 2>&1"
        .. " && echo ok || echo fail",
      function(result)
        set_busy(false)
        if result:match("ok") then
          table.remove(nearby_cache, i)
          populate_nearby()
          refresh_paired()
        else
          row:set({ label = { string = "Pairing Failed", color = colors.red } })
        end
      end)
  end)
end

settings_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.BluetoothSettings'")
  bt_bracket:set({ popup = { drawing = false } })
end)

-- ── Popup toggle ────────────────────────────────────────────────────────────
local function collapse_popup()
  bt_bracket:set({ popup = { drawing = false } })
end

local function toggle_popup()
  local should_draw = bt_bracket:query().popup.drawing == "off"
  if should_draw then
    bt_bracket:set({ popup = { drawing = true } })
    populate_paired()
    refresh_paired()
    populate_nearby()
  else
    collapse_popup()
  end
end

bt_icon:subscribe("mouse.clicked", toggle_popup)
bt_icon:subscribe("mouse.exited.global", collapse_popup)

-- Bar icon reflects state: dim when off, bright when a device is connected.
local function refresh_bar_icon()
  sbar.exec(blueutil("--power") .. " 2>&1", function(power)
    if power:match("^%s*([01])%s*$") ~= "1" then
      bt_icon:set({ icon = { color = colors.grey } })
      return
    end
    sbar.exec(blueutil("--connected") .. " 2>/dev/null", function(connected)
      bt_icon:set({
        icon = { color = connected:match("%S") and colors.white or colors.blue },
      })
    end)
  end)
end

refresh_bar_icon()
bt_icon:subscribe("system_woke", refresh_bar_icon)
