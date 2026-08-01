local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local shell = require("helpers.shell")

-- YBAR PORT: Bluetooth popup mimicking macOS Settings > Bluetooth:
-- header with a working power toggle, My Devices as two-line cells
-- (name, then Connected/Not Connected · battery), Nearby Devices that
-- auto-scans on open with the spinner beside the section header, and
-- pair-on-click for discovered devices.
-- Requires blueutil; the daemon needs Bluetooth access (Privacy & Security).

local popup_width = 320
local inset = 12
local max_devices = 6

local bt_script = SKETCHYBAR_CONFIG .. "/helpers/bluetooth_battery.sh"

local blueutil_path = "/opt/homebrew/bin/blueutil"
if os.execute("test -x /opt/homebrew/bin/blueutil") == nil then
  blueutil_path = "/usr/local/bin/blueutil"
end
local function blueutil(args)
  return blueutil_path .. " " .. args
end

-- The real Bluetooth logo lives only in the symbols Nerd Font (PUA needs
-- the family set explicitly); the rune ᛒ falls back fine inline with text.
local nf_family = "Symbols Nerd Font"
local bt_logo = "\u{F00AF}"
local glyph_toggle_on = "\u{F0521}"
local glyph_toggle_off = "\u{F0522}"
local bt_glyph = "ᛒ"

local type_icons = {
  headset  = "􀑈",
  keyboard = "􀇳",
  trackpad = "􀟀",
  phone    = "􀟜",
  speaker  = "􀝎",
  generic  = bt_glyph,
}

-- ── Bar pill ────────────────────────────────────────────────────────────────
local bt_icon = sbar.add("item", "widgets.bluetooth", {
  position = "right",
  icon = {
    string = bt_logo,
    font = { family = nf_family, size = 15.0 },
    color = colors.blue,
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
  padding_left = 2,
  padding_right = 2,
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

-- ── Header: "Bluetooth" + power toggle (click the row to flip it) ──────────
local header = sbar.add("item", "widgets.bluetooth.popup.header", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "Bluetooth",
    align = "left",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = glyph_toggle_on,
    align = "right",
    font = { family = nf_family, size = 18 },
    color = colors.white,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

-- Shown only when blueutil is TCC-denied.
local access_row = sbar.add("item", "widgets.bluetooth.access", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    string = "Bluetooth access needed",
    align = "left",
    color = colors.grey,
    font = { size = 12.0 },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = "Open Privacy",
    align = "right",
    color = colors.white,
    font = { size = 12.0, style = settings.font.style_map["Semibold"] },
    width = popup_width / 2,
    padding_right = inset,
  },
})

local function add_section_header(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      align = "left",
      string = title,
      color = colors.white,
      font = { size = 13, style = settings.font.style_map["Bold"] },
      width = popup_width / 2,
      padding_left = inset,
    },
    label = {
      align = "right",
      string = "",
      color = colors.grey,
      width = popup_width / 2,
      padding_right = inset,
    },
    padding_top = 6,
  })
end

-- My Devices: two rows per device — name, then an indented status line.
local my_header = add_section_header("My Devices")

local paired_name_rows = {}
local paired_status_rows = {}
for i = 1, max_devices do
  paired_name_rows[i] = sbar.add("item", "widgets.bluetooth.dev." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    icon = {
      string = "",
      color = colors.white,
      font = { size = 13.0 },
      width = popup_width - 20,
      align = "left",
      padding_left = inset + 6,
    },
    label = { drawing = false },
  })
  paired_status_rows[i] = sbar.add("item", "widgets.bluetooth.devstatus." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    icon = {
      string = "",
      color = colors.grey,
      font = { size = 11.0 },
      width = popup_width - 20,
      align = "left",
      padding_left = inset + 28,
    },
    label = { drawing = false },
  })
end

-- Nearby Devices: auto-scan on open, spinner beside the header.
local nearby_header = add_section_header("Nearby Devices")

local nearby_rows = {}
for i = 1, max_devices do
  nearby_rows[i] = sbar.add("item", "widgets.bluetooth.near." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    icon = {
      string = "",
      color = colors.grey,
      font = { size = 12.0 },
      width = popup_width - 110,
      align = "left",
      padding_left = inset + 6,
    },
    label = {
      string = "",
      color = colors.grey,
      font = { size = 11.0, style = settings.font.style_map["Semibold"] },
      width = 100,
      align = "right",
      padding_right = inset,
    },
  })
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
    string = icons.gear .. "  Settings",
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = popup_width - 20,
    padding_left = inset,
  },
  label = { drawing = false },
})

-- ── State ──────────────────────────────────────────────────────────────────
local paired_cache = {}   -- { name, address, connected, battery, dtype }
local nearby_cache = {}   -- { name, address }
local bt_power = true
local access_denied = false
local busy = false

-- Spinner beside "Nearby Devices" while an inquiry runs.
local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 0

local function spin()
  if not busy then
    nearby_header:set({ label = { string = "" } })
    return
  end
  spinner_index = spinner_index % #spinner_frames + 1
  nearby_header:set({ label = { string = spinner_frames[spinner_index] } })
  sbar.delay(0.1, spin)
end

-- ── Populate ───────────────────────────────────────────────────────────────
local function populate()
  header:set({
    label = {
      string = bt_power and glyph_toggle_on or glyph_toggle_off,
      color = access_denied and colors.grey or colors.white,
    },
  })
  access_row:set({ drawing = access_denied })

  local show = bt_power and not access_denied
  my_header:set({ drawing = show and #paired_cache > 0 })
  for i = 1, max_devices do
    local dev = show and paired_cache[i] or nil
    if dev then
      local status = dev.connected and "Connected" or "Not Connected"
      if dev.connected and dev.battery >= 0 then
        status = status .. " · " .. dev.battery .. "%"
      end
      paired_name_rows[i]:set({
        drawing = true,
        icon = {
          string = (type_icons[dev.dtype] or type_icons.generic) .. "  " .. dev.name,
          color = colors.white,
        },
      })
      paired_status_rows[i]:set({
        drawing = true,
        icon = { string = status },
      })
    else
      paired_name_rows[i]:set({ drawing = false })
      paired_status_rows[i]:set({ drawing = false })
    end
  end

  nearby_header:set({ drawing = show })
  for i = 1, max_devices do
    local dev = show and nearby_cache[i] or nil
    if dev then
      nearby_rows[i]:set({
        drawing = true,
        icon = { string = bt_glyph .. "  " .. dev.name, color = colors.white },
        label = { string = "", color = colors.grey },
      })
    else
      nearby_rows[i]:set({ drawing = false })
    end
  end
end

-- ── Data refresh ───────────────────────────────────────────────────────────
local function refresh_paired(callback)
  sbar.exec(blueutil("--power") .. " 2>&1", function(power)
    local state = power:match("^%s*([01])%s*$")
    access_denied = state == nil
    bt_power = state == "1"
    if access_denied or not bt_power then
      paired_cache = {}
      populate()
      if callback then callback() end
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
      populate()
      if callback then callback() end
    end)
  end)
end

local function run_inquiry()
  if busy or access_denied or not bt_power then return end
  busy = true
  spin()
  sbar.exec(blueutil("--inquiry 8") .. " 2>/dev/null", function(output)
    busy = false
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
    if #nearby_cache == 0 then
      nearby_header:set({ label = { string = "none found" } })
    end
    populate()
  end)
end

-- Bar icon reflects state: dim when off/denied, bright when connected.
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

-- ── Interactions ───────────────────────────────────────────────────────────
local function collapse_popup()
  bt_bracket:set({ popup = { drawing = false } })
end

header:subscribe("mouse.clicked", function()
  if access_denied then
    sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth'")
    collapse_popup()
    return
  end
  header:set({ label = { string = "…" } })
  sbar.exec(blueutil("--power " .. (bt_power and "0" or "1")) .. " 2>/dev/null", function()
    sbar.delay(1, function()
      refresh_paired(run_inquiry)
      refresh_bar_icon()
    end)
  end)
end)

access_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth'")
  collapse_popup()
end)

local function toggle_connection(i)
  local dev = paired_cache[i]
  if not dev then return end
  paired_status_rows[i]:set({ icon = { string = dev.connected and "Disconnecting…" or "Connecting…" } })
  local action = dev.connected and "--disconnect" or "--connect"
  sbar.exec(blueutil(action .. " " .. shell.quote(dev.address)) .. " 2>/dev/null",
    function()
      sbar.delay(1, function()
        refresh_paired()
        refresh_bar_icon()
      end)
    end)
end

for i = 1, max_devices do
  paired_name_rows[i]:subscribe("mouse.clicked", function() toggle_connection(i) end)
  paired_status_rows[i]:subscribe("mouse.clicked", function() toggle_connection(i) end)
end

nearby_header:subscribe("mouse.clicked", run_inquiry)

for i, row in ipairs(nearby_rows) do
  row:subscribe("mouse.clicked", function()
    local dev = nearby_cache[i]
    if not dev or busy then return end
    busy = true
    row:set({ label = { string = "Pairing…", color = colors.white } })
    sbar.exec(
      blueutil("--pair " .. shell.quote(dev.address)) .. " >/dev/null 2>&1 && "
        .. blueutil("--connect " .. shell.quote(dev.address)) .. " >/dev/null 2>&1"
        .. " && echo ok || echo fail",
      function(result)
        busy = false
        if result:match("ok") then
          table.remove(nearby_cache, i)
          populate()
          refresh_paired()
          refresh_bar_icon()
        else
          row:set({ label = { string = "Pairing Failed", color = colors.red } })
        end
      end)
  end)
end

settings_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.BluetoothSettings'")
  collapse_popup()
end)

local function toggle_popup()
  local should_draw = bt_bracket:query().popup.drawing == "off"
  if should_draw then
    bt_bracket:set({ popup = { drawing = true } })
    populate()
    refresh_paired(run_inquiry)
  else
    collapse_popup()
  end
end

bt_icon:subscribe("mouse.clicked", toggle_popup)
bt_icon:subscribe("mouse.exited.global", collapse_popup)
bt_icon:subscribe("system_woke", refresh_bar_icon)

refresh_bar_icon()
