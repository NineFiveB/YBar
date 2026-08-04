local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: Wi-Fi popup mimicking the macOS Settings > Wi-Fi pane:
-- header with a working power toggle, the connected network with a green
-- status dot, Known Networks (saved via networksetup's preferred list) and
-- Other Networks sections, the scan spinner beside "Other Networks", and
-- lock + wifi glyphs on each row's right edge. Click a row to join it.

local popup_width = 300
local inset = 12
local max_known = 4
local max_other = 8

local wifi_scan_py = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/wifi_scan.py"

-- Right-edge glyphs come from the symbols-only Nerd Font (PUA needs the
-- family set explicitly); the toggle uses SF's switch symbols.
local nf_family = "Symbols Nerd Font"
local glyph_lock = "\u{F033E}"   -- nf-md-lock
local glyph_wifi = "\u{F05A9}"   -- nf-md-wifi
local glyph_toggle_on = "\u{F0521}"   -- nf-md-toggle_switch
local glyph_toggle_off = "\u{F0522}"  -- nf-md-toggle_switch_off

-- ── Bar pill ────────────────────────────────────────────────────────────────
local wifi = sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  icon = {
    string = icons.wifi.connected,
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
})

local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi.name,
}, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 }
})

local popup_pos = "popup." .. wifi_bracket.name

-- ── Header: "Wi-Fi" + power toggle (click the row to flip it) ──────────────
local header = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Wi-Fi",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = glyph_toggle_on,
    font = { family = nf_family, size = 18 },
    color = colors.white,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

-- Connected network block (name + lock/wifi, then the green status dot).
local current_name = sbar.add("item", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    align = "left",
    string = "",
    color = colors.white,
    font = { size = 13, style = settings.font.style_map["Semibold"] },
    width = popup_width - 70,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = "",
    font = { family = nf_family, size = 12 },
    color = colors.grey,
    width = 70,
    padding_right = inset,
  },
})

local current_status = sbar.add("item", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    align = "left",
    string = "•",
    color = colors.green,
    font = { size = 15, style = settings.font.style_map["Bold"] },
    width = 16,
    padding_left = inset,
  },
  label = {
    align = "left",
    string = "Connected",
    color = colors.grey,
    font = { size = 12 },
    width = popup_width - 18 - inset,
  },
})

-- ── Section: Known Networks ────────────────────────────────────────────────
local function add_section_header(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      align = "left",
      string = title,
      color = colors.white,
      font = { size = 13, style = settings.font.style_map["Bold"] },
      padding_left = inset,
    },
    -- No label slot: the scan spinner (image, align=r) trails the title
    -- directly; a fixed half-width label would push it past the row edge.
    label = { drawing = false },
    -- Content is title+spinner only now; anchor it left like Settings.
    align = "left",
    padding_top = 6,
  })
end

local function add_net_row(name)
  return sbar.add("item", name, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    icon = {
      align = "left",
      string = "",
      color = colors.grey,
      font = { size = 12.0 },
      width = popup_width - 70,
      padding_left = inset + 6,
    },
    label = {
      align = "right",
      string = "",
      font = { family = nf_family, size = 12 },
      color = colors.grey,
      width = 70,
      padding_right = inset,
    },
  })
end

local known_header = add_section_header("Known Networks")
local known_rows = {}
for i = 1, max_known do
  known_rows[i] = add_net_row("widgets.wifi.known." .. i)
end

-- ── Section: Other Networks (spinner lives in the header, like Settings) ───
local other_header = add_section_header("Other Networks")
local other_rows = {}
for i = 1, max_other do
  other_rows[i] = add_net_row("widgets.wifi.net." .. i)
end

-- ── Footer: ProtonVPN + Settings ───────────────────────────────────────────
sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local vpn_button = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "ProtonVPN",
    font = { size = 13, style = settings.font.style_map["Bold"] },
    color = colors.grey,
    align = "left",
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = "Checking...",
    font = { size = 12, style = settings.font.style_map["Semibold"] },
    color = colors.grey,
    width = popup_width / 2,
    align = "right",
    padding_right = inset,
  },
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

-- ── State ──────────────────────────────────────────────────────────────────
local scan_cache = {}
local preferred_set = {}
local wifi_power = true
local is_connected = false
local scan_running = false

-- Spinner beside "Other Networks" while a scan runs (SF circular spinner).
local spinner = require("helpers.spinner").attach(other_header)

local function right_glyphs(net)
  return (net.secured and (glyph_lock .. "  ") or "") .. glyph_wifi
end

local function signal_color(net)
  if net.current then return colors.white end
  if net.rssi <= -900 then return colors.grey end
  if net.rssi >= -60 then return colors.white end
  if net.rssi >= -75 then return colors.blue end
  return colors.grey
end

-- Split the scan into current / known (saved) / other.
local function classify()
  local current, known, other = nil, {}, {}
  for _, net in ipairs(scan_cache) do
    if net.current then
      current = net
    elseif preferred_set[net.name] then
      known[#known + 1] = net
    else
      other[#other + 1] = net
    end
  end
  return current, known, other
end

local function populate_rows()
  local current, known, other = classify()

  header:set({
    label = { string = wifi_power and glyph_toggle_on or glyph_toggle_off },
  })

  local show_current = wifi_power and current ~= nil
  current_name:set({
    drawing = show_current,
    icon = { string = current and current.name or "" },
    label = { string = current and right_glyphs(current) or "" },
  })
  current_status:set({ drawing = show_current and is_connected })

  -- Known Networks: the current one first with a check, then other saved ones.
  local known_list = {}
  if current then known_list[1] = current end
  for _, net in ipairs(known) do known_list[#known_list + 1] = net end
  known_header:set({ drawing = wifi_power and #known_list > 0 })
  for i, row in ipairs(known_rows) do
    local net = wifi_power and known_list[i] or nil
    if net then
      row:set({
        drawing = true,
        icon = {
          string = (net.current and "✓  " or "") .. net.name,
          color = net.current and colors.white or colors.grey,
        },
        label = { string = right_glyphs(net), color = signal_color(net) },
      })
    else
      row:set({ drawing = false })
    end
  end

  other_header:set({ drawing = wifi_power })
  for i, row in ipairs(other_rows) do
    local net = wifi_power and other[i] or nil
    if net then
      row:set({
        drawing = true,
        icon = { string = net.name, color = colors.grey },
        label = { string = right_glyphs(net), color = signal_color(net) },
      })
    else
      row:set({ drawing = false })
    end
  end
end

-- ── Data refresh ───────────────────────────────────────────────────────────
local function run_scan()
  if scan_running or not wifi_power then return end
  scan_running = true
  spinner.start()
  sbar.exec(
    "system_profiler SPAirPortDataType -json 2>/dev/null | python3 '"
      .. wifi_scan_py:gsub("'", "'\\''") .. "'",
    function(output)
      scan_running = false
      spinner.stop()
      local nets = {}
      for line in output:gmatch("[^\r\n]+") do
        local cur, name, rssi, sec = line:match("^(%d)\t(.-)\t(%-?%d+)\t(%d)$")
        if name then
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
    end)
end

local function refresh_preferred(callback)
  sbar.exec("networksetup -listpreferredwirelessnetworks en0 2>/dev/null", function(out)
    preferred_set = {}
    for line in out:gmatch("[^\r\n]+") do
      local name = line:match("^%s+(.-)%s*$")
      if name and name ~= "" then preferred_set[name] = true end
    end
    if callback then callback() end
  end)
end

local function refresh_power(callback)
  sbar.exec("networksetup -getairportpower en0 2>/dev/null", function(out)
    wifi_power = out:match(": On") ~= nil
    if callback then callback() end
  end)
end

local function refresh_pill_icon()
  sbar.exec("ipconfig getifaddr en0", function(ip)
    is_connected = ip:match("%S") ~= nil
    wifi:set({
      icon = {
        string = is_connected and icons.wifi.connected or icons.wifi.disconnected,
        color = is_connected and colors.white or colors.red,
      },
    })
    current_status:set({ drawing = is_connected })
  end)
end

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

local function full_refresh()
  refresh_power(function()
    populate_rows()
    if wifi_power then
      refresh_preferred(populate_rows)
      run_scan()
    end
  end)
  refresh_pill_icon()
  update_vpn_status()
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function hide_details()
  wifi_bracket:set({ popup = { drawing = false } })
end

header:subscribe("mouse.clicked", function()
  local target = wifi_power and "off" or "on"
  header:set({ label = { string = "…" } })
  sbar.exec("networksetup -setairportpower en0 " .. target, function()
    sbar.delay(2, full_refresh)
  end)
end)

local function join(net, row)
  if not net or net.current then return end
  row:set({ icon = { string = "Joining " .. net.name .. "…" } })
  sbar.exec(
    "networksetup -setairportnetwork en0 '" .. net.name:gsub("'", "'\\''") .. "'",
    function(output)
      if output:match("%S") then
        sbar.exec("open 'x-apple.systempreferences:com.apple.wifi-settings-extension'")
      end
      hide_details()
      sbar.delay(3, full_refresh)
    end)
end

for i, row in ipairs(known_rows) do
  row:subscribe("mouse.clicked", function()
    local current, known = classify()
    local known_list = {}
    if current then known_list[1] = current end
    for _, net in ipairs(known) do known_list[#known_list + 1] = net end
    join(known_list[i], row)
  end)
end

for i, row in ipairs(other_rows) do
  row:subscribe("mouse.clicked", function()
    local _, _, other = classify()
    join(other[i], row)
  end)
end

settings_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.wifi-settings-extension'")
  hide_details()
end)

-- ProtonVPN registers a system VPN profile, so the tunnel can be driven
-- directly (scutil --nc start/stop) — no need to open the app. The app
-- only becomes the fallback when the service never reaches a terminal
-- state (e.g. profile removed or needs re-auth).
local vpn_busy = false

local function poll_vpn(want, attempt)
  sbar.exec("scutil --nc status ProtonVPN 2>/dev/null | head -1", function(out)
    local state = out:gsub("%s+", "")
    if state == want then
      vpn_busy = false
      update_vpn_status()
      return
    end
    if (attempt or 0) < 8 then
      sbar.delay(1, function() poll_vpn(want, (attempt or 0) + 1) end)
    else
      vpn_busy = false
      -- Couldn't reach the requested state (e.g. Proton's auto-reconnect
      -- reviving a stopped tunnel) — hand off to the app.
      sbar.exec("open -a ProtonVPN")
      update_vpn_status()
    end
  end)
end

vpn_button:subscribe("mouse.clicked", function()
  if vpn_busy then return end
  vpn_busy = true
  sbar.exec("scutil --nc status ProtonVPN 2>/dev/null | head -1", function(out)
    local connected = out:match("^Connected") ~= nil
    vpn_button:set({
      label = {
        string = connected and "Disconnecting…" or "Connecting…",
        color = colors.grey,
      },
    })
    sbar.exec("scutil --nc " .. (connected and "stop" or "start")
      .. " ProtonVPN 2>/dev/null", function()
      sbar.delay(1.5, function()
        poll_vpn(connected and "Disconnected" or "Connected", 0)
      end)
    end)
  end)
end)

local function toggle_details()
  local should_draw = wifi_bracket:query().popup.drawing == "off"
  if should_draw then
    wifi_bracket:set({ popup = { drawing = true } })
    populate_rows()
    full_refresh()
  else
    hide_details()
  end
end

wifi:subscribe("mouse.clicked", toggle_details)
wifi:subscribe("mouse.exited.global", hide_details)
wifi:subscribe({ "wifi_change", "system_woke" }, refresh_pill_icon)

sbar.add("item", { position = "right", width = settings.group_paddings })

-- Warm caches at load so the first popup opens populated.
refresh_preferred()
run_scan()
refresh_pill_icon()
