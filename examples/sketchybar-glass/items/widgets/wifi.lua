local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: Wi-Fi popup mimicking the Settings > Wi-Fi pane: header with
-- the radio state on the right, the connected network with a green status
-- dot, a details section, and a Settings footer.
--
-- WINDOWS PORT: the pill is driven by the native wifi_change event
-- (INFO = ssid | "connected" | "" offline) — ipconfig/networksetup are
-- gone. The popup fills from a single `netsh wlan show interfaces` round
-- trip on open (SSID, signal, receive/transmit rate, channel, radio type).
-- Dropped relative to macOS, each for lack of a Windows surface:
--   - Known/Other network scan + join rows: the scan came from
--     system_profiler + a python helper and joins from networksetup;
--     `netsh wlan show networks` needs location consent on Win11 24H2+ and
--     joining arbitrary (unsaved) networks has no non-interactive CLI, so
--     the sections are gone and the popup shows connection details instead.
--   - The header power toggle: flipping the radio needs an elevated netsh
--     or the WinRT Radio API — no non-admin CLI. The header shows On/Off
--     (from netsh's "Software Off" radio status) and clicking it opens the
--     Wi-Fi settings page.
--   - The ProtonVPN row: it was driven by scutil --nc (a macOS system VPN
--     profile); the ProtonVPN Windows app exposes no CLI for status or
--     connect, so the row is dropped.
--   - The Nerd Font right-edge glyphs: replaced with sf: references
--     (lock / wifi) resolved against Segoe Fluent Icons.
-- NOTE: netsh output is localized; the parse below assumes an English
-- Windows. The macOS file samples no throughput, so there are no
-- upload/download speed rows to port.

local popup_width = 300
local inset = 12

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

-- ── Header: "Wi-Fi" + radio state (click opens the Wi-Fi settings page) ────
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
    string = "On",
    font = { size = 13, style = settings.font.style_map["Bold"] },
    color = colors.white,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

-- Connected network block (name + lock/wifi glyph, then the green dot).
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
  -- The engine resolves `sf:` references only when they are the entire
  -- string, so the right edge carries one glyph (lock when secured, wifi
  -- otherwise) instead of macOS's concatenated lock+wifi pair.
  label = {
    align = "right",
    string = "",
    font = { size = 12 },
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

-- ── Section: Details (spinner lives in the header while netsh runs) ────────
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
    -- Content is title+spinner only; anchor it left like Settings.
    align = "left",
    padding_top = 6,
  })
end

local function add_detail_row(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      align = "left",
      string = title,
      color = colors.grey,
      font = { size = 12.0 },
      width = (popup_width / 2) - 6,
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

local details_header = add_section_header("Details")
local signal_row  = add_detail_row("Signal")
local channel_row = add_detail_row("Channel")
local radio_row   = add_detail_row("Radio Type")
local rx_row      = add_detail_row("Receive Rate")
local tx_row      = add_detail_row("Transmit Rate")

-- ── Footer: Settings ───────────────────────────────────────────────────────
sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

-- Glyph and text sit in separate slots: the engine resolves `sf:` refs
-- only as whole strings, so macOS's `icons.gear .. "  Settings"` concat
-- would shape as a single unresolvable icon name.
local settings_row = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = icons.gear,
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = 24,
    padding_left = inset,
  },
  label = {
    string = "Settings",
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = popup_width - 24 - inset,
  },
})

-- ── State ──────────────────────────────────────────────────────────────────
local wifi_power = true
local is_connected = false
local details_running = false
local details = nil   -- last parsed netsh snapshot

-- Spinner beside "Details" while the netsh round trip runs.
local spinner = require("helpers.spinner").attach(details_header)

local function right_glyph(secured)
  return secured and "sf:lock" or "sf:wifi"
end

-- netsh reports quality as a percentage: quality = 2 * (dBm + 100),
-- clamped — so the macOS thresholds (-60 / -75 dBm) map to 80% / 50%.
local function signal_color(pct)
  if not pct then return colors.grey end
  if pct >= 80 then return colors.white end
  if pct >= 50 then return colors.blue end
  return colors.grey
end

local function populate_rows()
  local d = details or {}

  header:set({ label = { string = wifi_power and "On" or "Off" } })

  local show_current = wifi_power and is_connected and d.ssid and d.ssid ~= ""
  current_name:set({
    drawing = show_current or false,
    icon = { string = d.ssid or "" },
    label = { string = right_glyph(d.secured), color = signal_color(d.signal) },
  })
  current_status:set({ drawing = (show_current and is_connected) or false })

  local have = wifi_power and is_connected
  signal_row:set({
    label = {
      string = (have and d.signal) and (d.signal .. "%") or "—",
      color = have and signal_color(d.signal) or colors.grey,
    },
  })
  channel_row:set({ label = { string = (have and d.channel) or "—" } })
  radio_row:set({ label = { string = (have and d.radio) or "—" } })
  rx_row:set({ label = { string = (have and d.rx) and (d.rx .. " Mbps") or "—" } })
  tx_row:set({ label = { string = (have and d.tx) and (d.tx .. " Mbps") or "—" } })
end

-- ── Data refresh ───────────────────────────────────────────────────────────
-- One netsh round trip, collapsed by awk into a single "|"-separated line:
-- state|ssid|signal|rx|tx|radio|channel|auth|power. `^ *SSID` does not
-- match the BSSID line; "Software Off" is the radio-off continuation line.
local netsh_cmd = "netsh wlan show interfaces | tr -d '\\r' | awk -F' : ' '"
  .. 'BEGIN{pwr="on"} '
  .. '/^ *State/{st=$2} '
  .. '/^ *SSID/{ssid=$2} '
  .. '/^ *Signal/{sig=$2} '
  .. '/^ *Receive rate/{rx=$2} '
  .. '/^ *Transmit rate/{tx=$2} '
  .. '/^ *Radio type/{rt=$2} '
  .. '/^ *Channel/{ch=$2} '
  .. '/^ *Authentication/{auth=$2} '
  .. '/Software Off/{pwr="off"} '
  .. 'END{printf "%s|%s|%s|%s|%s|%s|%s|%s|%s", st, ssid, sig, rx, tx, rt, ch, auth, pwr}'
  .. "'"

local function apply_pill()
  wifi:set({
    icon = {
      string = is_connected and icons.wifi.connected or icons.wifi.disconnected,
      color = is_connected and colors.white or colors.red,
    },
  })
end

local function refresh_details()
  if details_running then return end
  details_running = true
  spinner.start()
  sbar.exec(netsh_cmd, function(out)
    details_running = false
    spinner.stop()
    local st, ssid, sig, rx, tx, rt, ch, auth, pwr =
      out:match("^(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)|(.-)%s*$")
    if st then
      details = {
        ssid = ssid ~= "" and ssid or nil,
        signal = tonumber((sig or ""):match("(%d+)")),
        rx = rx ~= "" and rx or nil,
        tx = tx ~= "" and tx or nil,
        radio = rt ~= "" and rt or nil,
        channel = ch ~= "" and ch or nil,
        secured = auth ~= "" and not auth:match("^Open"),
      }
      wifi_power = pwr ~= "off"
      -- Belt behind the wifi_change event: the same round trip also
      -- refreshes the pill (covers boot, before any event fires).
      is_connected = st == "connected"
      apply_pill()
    end
    populate_rows()
  end)
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function hide_details()
  wifi_bracket:set({ popup = { drawing = false } })
end

-- macOS flipped the radio here (networksetup -setairportpower); Windows has
-- no non-admin CLI for that, so the header hands off to the settings page.
header:subscribe("mouse.clicked", function()
  sbar.exec('explorer.exe "ms-settings:network-wifi"')
  hide_details()
end)

settings_row:subscribe("mouse.clicked", function()
  sbar.exec('explorer.exe "ms-settings:network-wifi"')
  hide_details()
end)

local function toggle_details()
  local should_draw = wifi_bracket:query().popup.drawing == "off"
  if should_draw then
    wifi_bracket:set({ popup = { drawing = true } })
    populate_rows()       -- last snapshot first, then the fresh round trip
    refresh_details()
  else
    hide_details()
  end
end

-- Pill state rides the native event; INFO = ssid | "connected" | "" offline.
local function on_wifi_event(env)
  if env and env.SENDER == "wifi_change" then
    is_connected = env.INFO ~= ""
    apply_pill()
    current_status:set({ drawing = is_connected and (details ~= nil) })
  else
    -- system_woke: replay the event so the daemon re-reads live state.
    sbar.exec("ybar --trigger wifi_change")
  end
end

wifi:subscribe("mouse.clicked", toggle_details)
wifi:subscribe("mouse.exited.global", hide_details)
wifi:subscribe({ "wifi_change", "system_woke" }, on_wifi_event)

sbar.add("item", { position = "right", width = settings.group_paddings })

-- Warm caches at load so the first popup opens populated (also styles the
-- pill before the first wifi_change fires).
refresh_details()
