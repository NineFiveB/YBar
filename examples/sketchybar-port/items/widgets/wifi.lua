local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: rebuilt as a native-style Wi-Fi menu. The old widget showed
-- up/down speeds on the bar (dead helper binary -> "??? Bps") and a popup of
-- device details whose SSID macOS now redacts. This one is a single wifi pill
-- whose popup lists nearby networks (click to join) like the system menu,
-- plus the ProtonVPN row driven by the real tunnel state.

local popup_width = 250
local max_networks = 8

-- Scanner: system_profiler is the one CLI that still reports real SSIDs, but
-- it takes ~10s — so results are cached, shown instantly, refreshed behind.
local wifi_scan_py = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/wifi_scan.py"

local wifi = sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  icon = {
    string = icons.wifi.connected,
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
})

-- Background around the item
local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi.name,
}, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 }
})

local header = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  icon = {
    align = "left",
    string = "Wi-Fi",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
  },
  label = {
    align = "right",
    string = "scanning…",
    color = colors.grey,
    width = popup_width / 2,
  },
  width = popup_width,
  background = {
    height = 2,
    color = colors.grey,
    y_offset = -15,
  },
})

-- One popup row per nearby network, populated from the scan cache.
local net_rows = {}
for i = 1, max_networks do
  local row = sbar.add("item", "widgets.wifi.net." .. i, {
    position = "popup." .. wifi_bracket.name,
    drawing = false,
    width = popup_width,
    icon = {
      string = icons.wifi.connected,
      width = 28,
      align = "left",
    },
    label = {
      align = "left",
      width = popup_width - 28,
      max_chars = 24,
    },
  })
  net_rows[i] = row
end

local scan_cache = {}
local scan_running = false

local function signal_color(net)
  if net.current then return colors.white end
  if net.rssi <= -900 then return colors.grey end
  if net.rssi >= -60 then return colors.white end
  if net.rssi >= -75 then return colors.blue end
  return colors.grey
end

local function populate_rows()
  if #scan_cache == 0 then return end
  header:set({ label = { string = scan_running and "scanning…" or "" } })
  for i, row in ipairs(net_rows) do
    local net = scan_cache[i]
    if net then
      row:set({
        drawing = true,
        icon = { color = signal_color(net) },
        label = {
          string = net.name .. (net.current and "  ✓" or ""),
          color = net.current and colors.white or colors.grey,
          font = { style = settings.font.style_map[net.current and "Bold" or "Regular"] },
        },
      })
    else
      row:set({ drawing = false })
    end
  end
end

local function run_scan()
  if scan_running then return end
  scan_running = true
  header:set({ label = { string = "scanning…" } })
  sbar.exec(
    "system_profiler SPAirPortDataType -json 2>/dev/null | python3 '"
      .. wifi_scan_py:gsub("'", "'\\''") .. "'",
    function(output)
      scan_running = false
      local nets = {}
      for line in output:gmatch("[^\r\n]+") do
        local cur, name, rssi, sec = line:match("^(%d)\t(.-)\t(%-?%d+)\t(%d)$")
        if name and #nets < max_networks then
          nets[#nets + 1] = {
            current = cur == "1",
            name = name,
            rssi = tonumber(rssi),
            secured = sec == "1",
          }
        end
      end
      if #nets > 0 then scan_cache = nets end
      populate_rows()
      header:set({ label = { string = "" } })
    end)
end

-- ── Wi-Fi Settings + ProtonVPN ──────────────────────────────────────────────
sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  background = {
    height = 2,
    color = colors.grey,
    y_offset = -15,
  },
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
})

local settings_row = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  width = popup_width,
  icon = {
    string = icons.gear,
    width = 28,
    align = "left",
  },
  label = {
    string = "Wi-Fi Settings…",
    align = "left",
    width = popup_width - 28,
  },
})

local vpn_button = sbar.add("item", {
  position = "popup." .. wifi_bracket.name,
  width = popup_width,
  icon = {
    string = "ProtonVPN",
    font = { size = 13, style = settings.font.style_map["Bold"] },
    color = colors.grey,
    align = "left",
    width = popup_width / 2,
  },
  label = {
    string = "Checking...",
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 11.0,
    },
    color = colors.grey,
    width = popup_width / 2,
    align = "right",
  },
})

-- YBAR PORT: the app being open says nothing about the tunnel. scutil
-- reports the VPN service's live state ("(Connected)") — the same source
-- the system uses.
local function update_vpn_status()
  sbar.exec("scutil --nc list 2>/dev/null | grep -i proton", function(output)
    local connected = output:match("%(Connected%)") ~= nil
    local present = output:match("%S") ~= nil
    vpn_button:set({
      icon = { color = connected and colors.green or colors.grey },
      label = {
        string = connected and "Connected"
          or (present and "Not Connected" or "Not Installed"),
        color = connected and colors.green or colors.grey,
      },
    })
  end)
end

vpn_button:subscribe("mouse.clicked", function()
  sbar.exec("open -a ProtonVPN")
end)

sbar.add("item", { position = "right", width = settings.group_paddings })

local function refresh_pill_icon()
  sbar.exec("ipconfig getifaddr en0", function(ip)
    local connected = not (ip == "")
    wifi:set({
      icon = {
        string = connected and icons.wifi.connected or icons.wifi.disconnected,
        color = connected and colors.white or colors.red,
      },
    })
  end)
end

wifi:subscribe({ "wifi_change", "system_woke" }, refresh_pill_icon)

local function hide_details()
  wifi_bracket:set({ popup = { drawing = false } })
end

local function toggle_details()
  local should_draw = wifi_bracket:query().popup.drawing == "off"
  if should_draw then
    wifi_bracket:set({ popup = { drawing = true } })
    populate_rows()
    run_scan()
    update_vpn_status()
  else
    hide_details()
  end
end

wifi:subscribe("mouse.clicked", toggle_details)
wifi:subscribe("mouse.exited.global", hide_details)

-- Click a network row: join it (works for known/open networks — macOS uses
-- the saved password). Anything needing interactive auth lands in Wi-Fi
-- Settings instead.
for i, row in ipairs(net_rows) do
  row:subscribe("mouse.clicked", function()
    local net = scan_cache[i]
    if not net or net.current then return end
    row:set({ label = { string = "Joining " .. net.name .. "…" } })
    sbar.exec(
      "networksetup -setairportnetwork en0 '" .. net.name:gsub("'", "'\\''") .. "'",
      function(output)
        if output:match("%S") then
          -- Needs a password (or failed) — hand off to the system UI.
          sbar.exec("open 'x-apple.systempreferences:com.apple.wifi-settings-extension'")
        end
        hide_details()
        sbar.delay(3, function()
          refresh_pill_icon()
          run_scan()
        end)
      end)
  end)
end

settings_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.wifi-settings-extension'")
  hide_details()
end)

-- Warm the cache at load so the first popup opens populated.
run_scan()
refresh_pill_icon()
