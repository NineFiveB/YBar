local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- WINDOWS PORT, second pass: the popup now mirrors the Windows 11 Fluent
-- Wi-Fi flyout (per request) instead of the Settings details pane:
--
--   Wi-Fi                              [toggle]
--   <connected ssid>                     lock
--    • Connected
--   <scanned network rows>
--   ──────────────────────────────
--   More Wi-Fi settings
--
-- The pill is still driven by the native wifi_change event (INFO = ssid |
-- "connected" | "" offline). State comes from one `netsh wlan show
-- interfaces` round trip; the network list from `netsh wlan show networks
-- mode=bssid` (live-verified here — plain mode emits no Signal lines, so
-- per-network strength needs the per-BSSID listing; on Win11 24H2+ the scan
-- can need location consent, in which case the list simply stays empty and
-- the flyout shows just the connected block). Clicking a row connects when
-- the network is a SAVED profile (`netsh wlan connect` has no
-- non-interactive join for unsaved ones — Settings covers those via the
-- footer). The header toggle and the footer both deep-link to
-- ms-settings:network-wifi: flipping the radio needs an elevated netsh or
-- the WinRT Radio API, no non-admin CLI.
-- NOTE: netsh output is localized; the parses assume an English Windows.

local popup_width = 264
local inset = 11
local MAX_NETS = 8
-- Width of the leading glyph column (signal arc + security badge). Every row
-- in the flyout indents its text by this, so names form one column.
local glyph_col = 49

-- ── Bar pill ────────────────────────────────────────────────────────────────
local wifi = sbar.add("item", "widgets.wifi.padding", {
  position = "right",
  icon = {
    string = icons.wifi.connected,
    padding_left = 7,
    padding_right = 7,
  },
  label = { drawing = false },
})

local wifi_bracket = sbar.add("bracket", "widgets.wifi.bracket", {
  wifi.name,
}, {
  background = { color = colors.mica }, -- tint over the Mica material
  popup = { align = "center", height = 26 }
})

require("helpers.hover").pill(wifi_bracket, wifi)

local popup_pos = "popup." .. wifi_bracket.name

-- ── Header: "Wi-Fi" + radio toggle (click opens the Wi-Fi settings page) ───
local header = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  -- Item-level align defaults to center, and the fixed icon+label slots fill
  -- the row exactly — so any transient extra advance (the probe spinner's
  -- image) turns the centering slack negative and shifts the whole header
  -- left while a probe runs. Left-align the item so the slack never applies.
  align = "left",
  icon = {
    align = "left",
    string = "Wi-Fi",
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = icons.switch.on,
    -- Literal Segoe Fluent toggle glyph — needs the explicit family (only
    -- sf: strings auto-select the icon font).
    font = { family = icons.switch.font, size = 16 },
    color = colors.blue,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -13 },
})

-- Connected network block (name + lock/wifi glyph, then the green dot).
local current_name = sbar.add("item", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  -- Item align defaults to CENTRE, and the fixed part widths fill the row, so
  -- any slack recentres the whole block — which is what pushed the connected
  -- name into the middle instead of the name column (same trap the header
  -- documents).
  align = "left",
  -- Structurally IDENTICAL to a scanned row: glyph column, then the name. The
  -- name lands in the shared column BY CONSTRUCTION rather than by a padding
  -- tuned to match it. A part starts where the previous part's advance ends,
  -- plus its own padding_left — and a part WITHOUT a fixed width advances by
  -- its paddings plus its ink, so an indent computed from paddings alone came
  -- out ~8pt (one badge glyph) short. A fixed width replaces ink + paddings
  -- outright, which is why the column is a width here and not a padding.
  -- It also puts this row's security badge in the same column as every other
  -- row's, instead of alone at the far right.
  icon = {
    align = "left",
    string = "", -- lock / unlock, set on update
    font = { family = icons.wifi.signal.font, size = 11.5 },
    color = colors.grey,
    width = glyph_col,
    padding_left = inset,
  },
  label = {
    align = "left",
    string = "",
    color = colors.white,
    font = { size = 11.5, style = settings.font.style_map["Semibold"] },
    width = popup_width - glyph_col - inset,
  },
})

local current_status = sbar.add("item", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  align = "left",
  icon = {
    align = "left",
    string = "•",
    color = colors.green,
    font = { size = 13, style = settings.font.style_map["Bold"] },
    -- The dot occupies the glyph column, so "Connected" starts in the name
    -- column with the SSID above it and the networks below — it used to sit
    -- in a third column of its own, aligned with neither.
    width = glyph_col,
    padding_left = inset,
  },
  label = {
    align = "left",
    string = "Connected",
    color = colors.grey,
    font = { size = 10.5 },
    width = popup_width - glyph_col - inset,
  },
})

-- ── Network list: fixed row pool bound per scan (flyout body) ──────────────
-- Items carry exactly two text parts, and a part must never mix PUA
-- glyphs with ssid text: Segoe Fluent Icons is a symbol font, and
-- DirectWrite never font-falls-back OUT of a symbol font, so regular
-- text in an icon-family part shapes to the icon font's .notdef boxes
-- (seen on screen; spec 7.4). Both PUA glyphs — the signal arc plus the
-- lock badge when secured — share the fixed-width icon run, like Win11's
-- lock-badged network glyph, and the ssid keeps the UI text face in the
-- label. The fixed icon width keeps the ssid column aligned.
local net_rows = {}
for i = 1, MAX_NETS do
  net_rows[i] = sbar.add("item", "widgets.wifi.net." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    align = "left",
    icon = {
      string = "",
      color = colors.white,
      font = { family = icons.wifi.signal.font, size = 11.5 },
      width = glyph_col,
      align = "left",
      padding_left = inset,
    },
    label = {
      string = "",
      color = colors.white,
      font = { size = 11.5 },
      width = popup_width - glyph_col - inset,
      align = "left",
    },
  })
  require("helpers.hover").row(net_rows[i])
end

-- ── Footer: More Wi-Fi settings ────────────────────────────────────────────
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
    string = "More Wi-Fi settings",
    align = "left",
    color = colors.white,
    font = { size = 10.5 },
    width = popup_width - inset,
    padding_left = inset,
  },
  label = { drawing = false },
})

require("helpers.hover").row(settings_row)

-- ── State ──────────────────────────────────────────────────────────────────
local wifi_power = true
local is_connected = false
local details_running = false
local scanning = false
local scan_gen = 0      -- bumping cancels the while-open rescan loop
local details = nil     -- last parsed `show interfaces` snapshot
local net_cache = {}    -- { ssid, secured, signal } rows from the last scan

-- Spinner beside "Wi-Fi" while the netsh round trips run.
local spinner = require("helpers.spinner").attach(header)

local function right_glyph(secured)
  local s = icons.wifi.signal
  return secured and s.lock or s.unlock
end

-- Quartile breakpoints over netsh's 0-100 Signal percent; no Signal line
-- (hidden/stale entry) parses as 0 and lands on the weakest arc.
local function signal_glyph(pct)
  local s = icons.wifi.signal
  if pct < 25 then return s._1
  elseif pct < 50 then return s._2
  elseif pct < 75 then return s._3
  end
  return s._4
end

-- ── Populate ───────────────────────────────────────────────────────────────
local function populate_rows()
  header:set({
    label = {
      string = wifi_power and icons.switch.on or icons.switch.off,
      color = wifi_power and colors.blue or colors.grey,
    },
  })

  local d = details or {}
  local show_current = wifi_power and is_connected and d.ssid and d.ssid ~= ""
  current_name:set({
    drawing = show_current or false,
    -- Badge in the glyph column, name in the name column — the same two slots
    -- a scanned row uses, so the columns line up without any tuning.
    icon = { string = right_glyph(d.secured) },
    label = { string = d.ssid or "" },
  })
  current_status:set({ drawing = (show_current and is_connected) or false })

  -- Scanned rows, connected network excluded (it owns the block above).
  local row = 0
  if wifi_power then
    for _, net in ipairs(net_cache) do
      if net.ssid ~= (d.ssid or "") and row < MAX_NETS then
        row = row + 1
        net_rows[row]:set({
          drawing = true,
          -- Badge FIRST, arc second. Both glyphs share one run, and Segoe
          -- Fluent's Wifi1..Wifi4 are proportional — the stronger the signal
          -- the wider the glyph — so with the arc leading, whatever followed
          -- it inherited that drift: the lock column wandered 5pt across the
          -- list (measured 100/97/94/90 px at 2x). The badge is the same glyph
          -- every row, so leading with it gives BOTH columns a fixed left edge
          -- and only the arc's own ink varies, which is the point of an arc.
          icon = { string = (net.secured and icons.wifi.signal.lock
                             or icons.wifi.signal.unlock)
            .. " " .. signal_glyph(net.signal or 0) },
          label = { string = net.ssid },
        })
      end
    end
  end
  for i = row + 1, MAX_NETS do
    net_rows[i]:set({ drawing = false })
  end
end

-- ── Data refresh ───────────────────────────────────────────────────────────
-- Connection state: one `show interfaces` round trip collapsed by awk into
-- "state|ssid|auth|power" ("Software Off" is the radio-off continuation
-- line; `^ *SSID` does not match the BSSID line).
-- Fields are tab-separated, not '|': an ssid may legally contain '|', which
-- would corrupt a pipe-delimited record (wrong field split on the Lua side).
local iface_cmd = "netsh wlan show interfaces | tr -d '\\r' | awk -F' : ' '"
  .. 'BEGIN{pwr="on"} '
  .. '/^ *State/{st=$2} '
  .. '/^ *SSID/{ssid=$2} '
  .. '/^ *Authentication/{auth=$2} '
  .. '/Software Off/{pwr="off"} '
  .. 'END{printf "%s\\t%s\\t%s\\t%s", st, ssid, auth, pwr}'
  .. "'"

-- Network scan: "net|<ssid>|<secured>|<signal>" per visible network. Only
-- mode=bssid emits Signal lines (one per BSSID — the strongest wins), so
-- emission waits for the next SSID header / END to let a network's BSSID
-- lines accumulate; a network with no Signal line reports 0.
-- Tab-separated fields (an ssid may contain '|'); "net" stays a line marker.
local scan_cmd = "netsh wlan show networks mode=bssid | tr -d '\\r' | awk -F' : ' '"
  .. '/^SSID/{ if (ssid != "") printf "net\\t%s\\t%d\\t%d\\n", ssid, sec, sig; '
  .. 'ssid=$2; sec=1; sig=0 } '
  .. '/^ *Authentication/{ sec = ($2 ~ /Open/) ? 0 : 1 } '
  .. '/^ *Signal/{ pct=$2; sub(/%/, "", pct); if (pct+0 > sig) sig=pct+0 } '
  .. 'END{ if (ssid != "") printf "net\\t%s\\t%d\\t%d\\n", ssid, sec, sig }'
  .. "'"

-- netsh only READS the results of Windows' most recent scan — it never
-- triggers one. The taskbar's native flyout is what normally forces
-- rescans, and this bar hides the taskbar, so without a nudge the listing
-- decays to just the connected network. WiFiAdapter.ScanAsync (WinRT, via
-- Windows PowerShell's in-box projection + the AsTask bridge — the raw
-- IAsyncOperation projects as a bare __ComObject in 5.1) forces a real
-- scan (~3-5 s, live-verified 1 -> 24 networks here); the netsh listing
-- right after reflects it. No adapter access (location consent denied on
-- 24H2+) leaves Result empty and this falls through to the stale listing.
local rescan_cmd = "powershell.exe -NoProfile -Command '"
  .. 'Add-Type -AssemblyName System.Runtime.WindowsRuntime; '
  .. '[Windows.Devices.WiFi.WiFiAdapter,Windows.Devices.WiFi,ContentType=WindowsRuntime]|Out-Null; '
  .. '$m=[System.WindowsRuntimeSystemExtensions].GetMethods(); '
  .. '$g=($m|Where-Object{$_.Name -eq \"AsTask\" -and $_.GetParameters().Count -eq 1'
  .. ' -and $_.GetParameters()[0].ParameterType.Name -like \"IAsyncOperation*\"})[0]; '
  .. '$a=($m|Where-Object{$_.Name -eq \"AsTask\" -and $_.GetParameters().Count -eq 1'
  .. ' -and $_.GetParameters()[0].ParameterType.Name -eq \"IAsyncAction\"})[0]; '
  .. '$t=$g.MakeGenericMethod([System.Collections.Generic.IReadOnlyList[Windows.Devices.WiFi.WiFiAdapter]])'
  .. '.Invoke($null,@([Windows.Devices.WiFi.WiFiAdapter]::FindAllAdaptersAsync())); '
  .. '$null=$t.Wait(5000); '
  .. 'if($t.Result.Count -gt 0){$s=$a.Invoke($null,@($t.Result[0].ScanAsync())); $null=$s.Wait(15000)}'
  .. "'"

local function apply_pill()
  wifi:set({
    icon = {
      string = is_connected and icons.wifi.connected or icons.wifi.disconnected,
      color = is_connected and colors.white or colors.red,
    },
  })
end

local function refresh_state()
  if details_running then return end
  details_running = true
  spinner.start()
  sbar.exec(iface_cmd, function(out)
    details_running = false
    spinner.stop()
    local st, ssid, auth, pwr = out:match("^(.-)\t(.-)\t(.-)\t(.-)%s*$")
    if st then
      details = {
        ssid = ssid ~= "" and ssid or nil,
        secured = auth ~= "" and not auth:match("^Open"),
      }
      wifi_power = pwr ~= "off"
      -- Belt behind the wifi_change event (covers boot, before any event).
      is_connected = st == "connected"
      apply_pill()
    end
    populate_rows()
  end)
end

local function scan_networks(silent)
  if scanning then return end
  scanning = true
  if not silent then spinner.start() end
  -- Force the OS scan first; the netsh listing right after reflects it.
  sbar.exec(rescan_cmd, function()
    sbar.exec(scan_cmd, function(out)
      scanning = false
      if not silent then spinner.stop() end
      net_cache = {}
      local seen = {}
      for ssid, sec, sig in (out or ""):gmatch("net\t([^\t\n]+)\t([01])\t(%d+)") do
        if not seen[ssid] then
          seen[ssid] = true
          net_cache[#net_cache + 1] =
            { ssid = ssid, secured = sec == "1", signal = tonumber(sig) }
        end
      end
      -- Strongest first: populate_rows caps at MAX_NETS rows, so without
      -- the sort a crowded neighborhood can crowd out the usable networks.
      table.sort(net_cache, function(a, b)
        return (a.signal or 0) > (b.signal or 0)
      end)
      populate_rows()
    end)
  end)
end

-- Win11's flyout keeps scanning for as long as it is open; mirror that.
-- Only the first pass spins the header — refreshes land silently. The
-- generation bump on hide (or a re-open) orphans the old loop.
local function scan_loop(gen, silent)
  if gen ~= scan_gen then return end
  scan_networks(silent)
  sbar.delay(12, function() scan_loop(gen, true) end)
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function hide_details()
  scan_gen = scan_gen + 1 -- ends the while-open rescan loop
  wifi_bracket:set({ popup = { drawing = false } })
end

local function open_wifi_settings()
  sbar.exec('explorer.exe "ms-settings:network-wifi"')
  hide_details()
end

-- No non-admin CLI flips the radio — the toggle hands off to Settings.
header:subscribe("mouse.clicked", open_wifi_settings)
settings_row:subscribe("mouse.clicked", open_wifi_settings)

-- The ssid reaches netsh through `sh -c` inside double quotes. Inside sh
-- double quotes only $, backtick and backslash keep meaning (and " ends the
-- quote), so any of those in a scanned ssid — an attacker names their AP
-- `$(...)` — would inject shell. Rather than escape through the MSYS
-- backslash-halving layer, refuse the CLI join for such ssids and fall
-- through to Settings, which joins safely via the OS UI. Everything else
-- (spaces, &, ;, ', parens, …) is literal inside the double quotes.
local function ssid_shell_safe(ssid)
  return not ssid:find('[%$`\\"]')
end

-- Row click: connect if the profile is saved (unsaved networks have no
-- non-interactive join — netsh just errors and the state refresh shrugs).
for i = 1, MAX_NETS do
  net_rows[i]:subscribe("mouse.clicked", function()
    -- populate_rows skips the connected ssid, so recover the row's binding
    -- the same way it was laid down.
    local d = details or {}
    local row = 0
    for _, net in ipairs(net_cache) do
      if net.ssid ~= (d.ssid or "") then
        row = row + 1
        if row == i then
          if ssid_shell_safe(net.ssid) then
            sbar.exec('netsh wlan connect name="' .. net.ssid .. '"')
            sbar.delay(4, function()
              refresh_state()
              scan_networks()
            end)
          else
            open_wifi_settings()
          end
          return
        end
      end
    end
  end)
end

local function toggle_details()
  local should_draw = wifi_bracket:query().popup.drawing == "off"
  if should_draw then
    wifi_bracket:set({ popup = { drawing = true } })
    populate_rows()      -- last snapshot first, then the fresh round trips
    refresh_state()
    scan_gen = scan_gen + 1
    scan_loop(scan_gen, false) -- scan now, then keep rescanning while open
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
-- pill before the first wifi_change fires). The silent scan means even the
-- very first open shows a real network list, not just the connected row.
refresh_state()
scan_networks(true)
scan_networks()
