local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- Liquid Glass Wi-Fi popup. The header keeps the green Connected status.
-- Each network is one wrapped line: name on the left, then an optional
-- Connect/Disconnect capsule, a small gap, a lock, and a signal fan.
-- Connect is gray and only appears on hover for a network YBar can join.
-- A locked unknown network that is on the air asks for its password in a
-- separate window. Saved networks, hotspots, and open networks do not.
-- The current network keeps Disconnect visible.

local line = 388
local edge = 6
local lock_w = 26
local signal_w = 26
local button_w = 96
local gap = 12
local max_rows = 6
local max_hotspots = 3
local disconnect_red = 0xccff453a

local wifi = sbar.add("item", "widgets.wifi", {
  position = "right",
  icon = {
    string = icons.wifi.connected,
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
})

local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", { wifi.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", wrap_width = line },
})

require("helpers.hover").pill(wifi_bracket, wifi)

local popup_pos = "popup." .. wifi_bracket.name

local header = sbar.add("item", {
  position = popup_pos,
  width = line,
  padding_left = 0,
  padding_right = 0,
  icon = {
    align = "left",
    string = "Wi-Fi",
    font = { size = 14, style = settings.font.style_map["Regular"] },
    width = line / 2,
    padding_left = 12,
  },
  label = {
    align = "right",
    string = "●  Connected",
    color = colors.connected,
    font = { size = 11, style = settings.font.style_map["Regular"] },
    width = line / 2,
    padding_right = 12,
  },
})

local function action_label(text, bg)
  return {
    string = text,
    drawing = true,
    align = "center",
    color = colors.white,
    font = { size = 11, style = settings.font.style_map["Regular"] },
    width = button_w,
    padding_left = 8,
    padding_right = 8,
    background = {
      color = bg,
      height = 20,
      corner_radius = 10,
      drawing = true,
      glass = false,
      sheen = false,
      padding_left = 8,
      padding_right = 8,
    },
  }
end

local function connect_label()
  return action_label("Connect", colors.button)
end

-- Connected rows keep Disconnect up. It turns red while the leave runs.
local function disconnect_label(pressed)
  return action_label("Disconnect", pressed and disconnect_red or colors.button)
end

local function hidden_piece()
  return {
    position = popup_pos,
    drawing = false,
    width = 0,
    icon = { drawing = false },
    label = { drawing = false },
    background = {
      height = 36,
      corner_radius = 12,
      color = colors.transparent,
      drawing = false,
      glass = false,
      sheen = false,
    },
  }
end

local function add_network_row(prefix, i)
  local name = sbar.add("item", prefix .. i .. ".name", hidden_piece())
  local button = sbar.add("item", prefix .. i .. ".button", hidden_piece())
  local lock = sbar.add("item", prefix .. i .. ".lock", hidden_piece())
  local signal = sbar.add("item", prefix .. i .. ".signal", hidden_piece())
  return { name = name, button = button, lock = lock, signal = signal }
end

local hotspot_rows = {}
for i = 1, max_hotspots do
  hotspot_rows[i] = add_network_row("widgets.wifi.hotspot.", i)
end

local known_rows = {}
for i = 1, max_rows do
  known_rows[i] = add_network_row("widgets.wifi.known.", i)
end

local scan_label = sbar.add("item", "widgets.wifi.scan", {
  position = popup_pos,
  width = line,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = "Looking for networks…",
    align = "left",
    color = colors.with_alpha(colors.white, 0.62),
    font = { size = 12 },
    width = line,
    padding_left = 12,
  },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.white, 0.12), y_offset = 12 },
})

local spinner = require("helpers.spinner").attach(scan_label, {
  size = 10, align = "l", padding_left = 12,
})

-- Second line of the no-Location notice: the one-time opt-in that raises
-- the prompt. Its own row because the whole sentence is wider than the
-- popup at the label's size.
local scan_hint = sbar.add("item", "widgets.wifi.scan.hint", {
  position = popup_pos,
  drawing = false,
  width = line,
  padding_left = 0,
  padding_right = 0,
  icon = {
    string = "ybar --bar wifi_ssid_prompt=on",
    align = "left",
    color = colors.with_alpha(colors.white, 0.62),
    font = { family = "Menlo", size = 11 },
    width = line,
    padding_left = 12,
  },
  label = { drawing = false },
})

local other_rows = {}
for i = 1, max_rows do
  other_rows[i] = add_network_row("widgets.wifi.other.", i)
end

local scan_cache = {}
local live_ssid = nil
-- Last wifi_change INFO: "" offline, the SSID on Wi-Fi with the Location
-- grant, "connected" for any other online path (wired, or Wi-Fi without
-- the grant).
local live_info = ""
local is_connected = false
local scan_running = false
-- A "connected" payload landed while a scan was in flight. That pass
-- predates the change, so one more follows when it returns; however many
-- payloads a burst delivers meanwhile, they collapse into that single
-- follow-up, and two scans never overlap.
local scan_pending = false
-- A scan has landed since the last "connected" payload; until one does,
-- that payload is taken at face value.
local scan_seen = false
-- The last scan saw networks but could name none: macOS withholds every
-- SSID until YBar holds the Location grant (wifi_scan exit code 3). The
-- joined network is still listed then, under the literal "<redacted>".
local scan_redacted = false
local disconnecting_name = nil
local joining_name = nil
local hovered_name = nil
local hover_seq = 0
local hotspot_list = {}
local known_list = {}
local other_list = {}

local function classify()
  local current, known, other, hotspots = nil, {}, {}, {}
  for _, net in ipairs(scan_cache) do
    if net.current then
      current = net
    elseif net.hotspot then
      hotspots[#hotspots + 1] = net
    elseif net.known then
      known[#known + 1] = net
    else
      other[#other + 1] = net
    end
  end
  if not current and live_ssid then
    current = {
      current = true, name = live_ssid, rssi = -50,
      known = true, hotspot = false, secure = true,
    }
  end
  hotspot_list = hotspots
  known_list = {}
  if current then known_list[1] = current end
  for _, net in ipairs(known) do known_list[#known_list + 1] = net end
  other_list = other
  return current
end

-- nil hides the fan (a saved hotspot that is not broadcasting).
local function signal_alpha(rssi)
  if not rssi or rssi <= -900 then return nil end
  if rssi >= -50 then return 1 end
  if rssi >= -67 then return 0.72 end
  return 0.45
end

-- Saved networks and hotspots use the keychain. Open networks need no
-- password. A locked unknown network that is broadcasting asks for one.
local function can_join(net)
  if not net or net.current then return false end
  if net.known or net.hotspot or net.secure == false then return true end
  return signal_alpha(net.rssi) ~= nil
end

local function needs_password(net)
  if not net or net.current then return false end
  if net.known or net.hotspot or net.secure == false then return false end
  return signal_alpha(net.rssi) ~= nil
end

local function wants_button(net)
  if not net then return false end
  if net.current then return true end
  return hovered_name == net.name and can_join(net)
end

local function paint_network(row, net)
  if not net then
    row.name:set({ drawing = false, width = 0, padding_left = 0 })
    row.button:set({ drawing = false, width = 0 })
    row.lock:set({ drawing = false, width = 0, padding_left = 0, padding_right = 0 })
    row.signal:set({ drawing = false, width = 0, padding_right = 0 })
    return
  end
  local fan = signal_alpha(net.rssi)
  local has_fan = fan ~= nil
  local button_on = wants_button(net)
  local tail = has_fan and (signal_w + edge) or edge
  local button_extra = button_on and (button_w + gap) or 0
  local name_w = line - edge - lock_w - tail - button_extra
  local on = net.current
  local title = (joining_name == net.name) and ("Joining " .. net.name .. "…") or net.name
  -- The connected row is one rounded plate, the same 12pt corners and 36pt
  -- height as a Bluetooth row. The lock and signal sit outside it.
  if on then
    row.name:set({
      drawing = true,
      width = name_w + button_w,
      padding_left = edge,
      padding_right = 0,
      background = {
        color = colors.selection,
        height = 36,
        corner_radius = 12,
        drawing = true,
      },
      icon = {
        drawing = true,
        string = title,
        align = "left",
        color = colors.white,
        font = { size = 13 },
        width = name_w,
        padding_left = 8,
        padding_right = 0,
      },
      label = disconnect_label(disconnecting_name == net.name),
    })
    row.button:set({
      drawing = false,
      width = 0,
      padding_left = 0,
      padding_right = 0,
      label = { drawing = false, background = { drawing = false } },
    })
  else
    row.name:set({
      drawing = true,
      width = name_w,
      padding_left = edge,
      padding_right = 0,
      background = { drawing = false },
      icon = {
        drawing = true,
        string = title,
        align = "left",
        color = colors.white,
        font = { size = 13 },
        width = name_w,
        padding_left = 8,
        padding_right = 0,
      },
      label = { drawing = false, background = { drawing = false } },
    })
    if button_on then
      row.button:set({
        drawing = true,
        width = button_w,
        padding_left = 0,
        padding_right = 0,
        background = { drawing = false },
        icon = { drawing = false },
        label = connect_label(),
      })
    else
      row.button:set({
        drawing = false,
        width = 0,
        padding_left = 0,
        padding_right = 0,
        label = { drawing = false, background = { drawing = false } },
      })
    end
  end
  row.lock:set({
    drawing = true,
    width = lock_w,
    padding_left = button_on and gap or 0,
    padding_right = has_fan and 0 or edge,
    background = { drawing = false },
    icon = {
      drawing = true,
      string = net.secure == false and "sf:lock.open" or "sf:lock",
      align = "center",
      color = colors.white,
      font = { size = 13 },
      width = lock_w,
      padding_left = 0,
      padding_right = 0,
    },
    label = { drawing = false },
  })
  if has_fan then
    row.signal:set({
      drawing = true,
      width = signal_w,
      padding_left = 0,
      padding_right = edge,
      background = { drawing = false },
      icon = {
        drawing = true,
        string = "sf:wifi",
        align = "center",
        color = colors.with_alpha(colors.white, fan),
        font = { size = 14 },
        width = signal_w,
        padding_left = 0,
        padding_right = 0,
      },
      label = { drawing = false },
    })
  else
    row.signal:set({ drawing = false, width = 0, padding_right = 0 })
  end
end

local function paint()
  classify()
  header:set({
    label = {
      string = is_connected and "●  Connected" or "Off",
      color = is_connected and colors.connected or colors.grey,
    },
  })
  for i, row in ipairs(hotspot_rows) do
    paint_network(row, hotspot_list[i])
  end
  for i, row in ipairs(known_rows) do
    paint_network(row, known_list[i])
  end
  for i, row in ipairs(other_rows) do
    paint_network(row, other_list[i])
  end
  if scan_running then
    scan_label:set({ drawing = true, icon = { string = "Looking for networks…" } })
  elseif scan_redacted then
    scan_label:set({ drawing = true, icon = { string = "Allow Location for YBar to list networks" } })
  elseif #other_list > 0 then
    scan_label:set({ drawing = true, icon = { string = "Other networks" } })
  else
    scan_label:set({ drawing = false })
  end
  scan_hint:set({ drawing = scan_redacted and not scan_running })
end

-- Whether the Wi-Fi interface is joined. wifi_change settles it outright
-- when INFO is "" or an SSID. "connected" only says some path is up —
-- wired, or Wi-Fi without the Location grant — and the scan's current row
-- tells the two apart: the scan lists the joined network even without the
-- grant. Until a scan lands the payload is taken at face value, the same
-- generic connected state docs/INSTALL.md promises without Location.
-- No ipconfig probe: en0 is the Wi-Fi interface on a laptop but Ethernet
-- on a desktop Mac.
local function wifi_connected()
  if live_info == "" then return false end
  if live_info ~= "connected" then return true end
  if not scan_seen then return true end
  for _, net in ipairs(scan_cache) do
    if net.current then return true end
  end
  return false
end

local function popup_open()
  return wifi_bracket:query().popup.drawing == "on"
end

local function refresh_pill()
  is_connected = wifi_connected()
  wifi:set({
    icon = {
      string = is_connected and icons.wifi.connected or icons.wifi.disconnected,
      color = is_connected and colors.white or colors.grey,
    },
  })
  paint()
end

local function run_scan()
  if scan_running then return end
  scan_running = true
  -- The spinner is an item:set every 40 ms, and most scans start from a
  -- wifi_change with the popup closed (the load-time seed, `ybar --update`,
  -- a path change). Spin only while the popup is drawn: toggle() starts it
  -- when the popup opens mid-scan, hide() stops it when the popup closes.
  if popup_open() then spinner.start() end
  paint()
  sbar.wifi_scan(function(output, code)
    scan_running = false
    spinner.stop()
    scan_seen = true
    scan_redacted = code == 3
    local nets = {}
    for line_text in (output or ""):gmatch("[^\r\n]+") do
      local cur, name, rssi, known, hotspot, secure =
        line_text:match("^(%d)\t(.-)\t(%-?%d+)\t(%d)\t(%d)\t(%d)$")
      if name and name ~= "" then
        nets[#nets + 1] = {
          current = cur == "1",
          name = name,
          rssi = tonumber(rssi),
          known = known == "1",
          hotspot = hotspot == "1",
          secure = secure == "1",
        }
      end
    end
    scan_cache = nets
    refresh_pill()
    if scan_pending then
      scan_pending = false
      run_scan()
    end
  end)
end

local function hide()
  hovered_name = nil
  spinner.stop()
  wifi_bracket:set({ popup = { drawing = false } })
end

local function disconnect(net, row)
  if not net or not net.current or disconnecting_name then return end
  disconnecting_name = net.name
  row.name:set({ label = disconnect_label(true) })
  sbar.wifi_disconnect(function()
    disconnecting_name = nil
    sbar.delay(1.2, function()
      refresh_pill()
      run_scan()
    end)
  end)
end

local function join(net, row)
  if not can_join(net) or joining_name or disconnecting_name then return end
  if needs_password(net) then
    -- The popup cannot take a keystroke. The panel names the network, stays
    -- open on a wrong password, and calls back once when it closes.
    hide()
    sbar.wifi_prompt(net.name, function(_, code)
      if code ~= 0 then return end
      sbar.delay(1.5, function()
        refresh_pill()
        run_scan()
      end)
    end)
    return
  end
  joining_name = net.name
  row.name:set({ icon = { string = "Joining " .. net.name .. "…" } })
  sbar.wifi_join(net.name, function(_, code)
    joining_name = nil
    if code ~= 0 then
      row.name:set({ icon = { string = net.name } })
    end
    sbar.delay(1.5, function()
      refresh_pill()
      run_scan()
    end)
  end)
end

local function bind(rows, which)
  for i, row in ipairs(rows) do
    local function net_at()
      if which == "hotspot" then return hotspot_list[i] end
      if which == "known" then return known_list[i] end
      return other_list[i]
    end
    local function clicked()
      local net = net_at()
      if not net then return end
      if net.current then
        disconnect(net, row)
      else
        join(net, row)
      end
    end
    local function entered()
      local net = net_at()
      if not can_join(net) then return end
      hover_seq = hover_seq + 1
      if hovered_name == net.name then return end
      hovered_name = net.name
      paint()
    end
    local function exited()
      local net = net_at()
      if not net or hovered_name ~= net.name then return end
      local seq = hover_seq
      sbar.delay(0.05, function()
        if hover_seq ~= seq then return end
        if hovered_name ~= net.name then return end
        hovered_name = nil
        paint()
      end)
    end
    for _, piece in ipairs({ row.name, row.button, row.lock, row.signal }) do
      piece:subscribe("mouse.clicked", clicked)
      piece:subscribe("mouse.entered", entered)
      piece:subscribe("mouse.exited", exited)
    end
  end
end

bind(hotspot_rows, "hotspot")
bind(known_rows, "known")
bind(other_rows, "other")

local function toggle()
  local open = wifi_bracket:query().popup.drawing == "off"
  if open then
    wifi_bracket:set({ popup = { drawing = true } })
    refresh_pill()
    if scan_running then spinner.start() else run_scan() end
  else
    hide()
  end
end

wifi:subscribe("mouse.clicked", toggle)
wifi:subscribe("mouse.exited.global", hide)
wifi:subscribe("wifi_change", function(env)
  local info = env.INFO or ""
  live_info = info
  if info ~= "" and info ~= "connected" then
    live_ssid = info
  else
    live_ssid = nil
  end
  -- Some path came up, or the Wi-Fi name went away: which interface is
  -- joined is a fresh scan's call now, not the last pass's.
  local settle = info == "connected"
  if settle then scan_seen = false end
  refresh_pill()
  if settle then
    if scan_running then scan_pending = true else run_scan() end
  end
end)

-- Seed the state. A config reload keeps the provider armed and deduped,
-- so nothing would arrive until the path next changed; the forced
-- re-query publishes it now (on a fresh start the first path update
-- follows on its own).
sbar.trigger("wifi_change")

sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  width = settings.group_paddings,
})
