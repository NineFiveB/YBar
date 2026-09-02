local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- WINDOWS PORT, second pass: the popup now mirrors the Windows 11 Fluent
-- Bluetooth quick-settings flyout (per request) instead of the macOS
-- Settings > Bluetooth pane it was first ported from:
--
--   Bluetooth                          [toggle]
--   <paired device rows>
--   ──────────────────────────────
--   More Bluetooth settings
--
-- blueutil does not exist and Windows ships no supported CLI for
-- toggling the radio, connecting, pairing, or inquiry scans — every
-- "action" click deep-links into explorer.exe "ms-settings:bluetooth"
-- instead. State comes from a single PowerShell probe run once at load
-- and once per popup open (no continuous polling): the header toggle
-- reflects the real radio power read through WinRT
-- Windows.Devices.Radios (On / Off / Disabled / absent — not a
-- PnP-node presence heuristic), and the device rows fill from the same
-- probe's Get-PnpDevice FriendlyName per BTHENUM/BTHLE device node.
-- Rows are single-line name-only: per-device battery and live
-- Connected/Not Connected state both need per-device DEVPKEY property
-- reads (extra round trips per device), so both stay dropped. The
-- Nearby Devices section (inquiry scan + pair-on-click) is dropped
-- entirely: no inquiry CLI on Windows.

local popup_width = 264
local inset = 11
local max_devices = 6

-- One probe, compact output parsed in Lua:
--   dev|<name>     (one line per paired device node)
--   state|<s>      (WinRT radio power: On / Off / Disabled / Unknown,
--                   or "none" when no Bluetooth radio exists)
-- Device lines print first so a WinRT hiccup cannot suppress them.
-- No backslashes anywhere in the regexes: the MSYS sh -> powershell.exe
-- spawn halves `\\` to `\`, which silently turned BTHENUM\\DEV_ into the
-- never-matching \D (non-digit) class — the device list came back empty.
-- `.` matches the literal backslash and survives every quoting layer.
-- UTF-8 output encoding keeps non-ASCII device names (curly apostrophes)
-- intact through the exec pipe.
-- The radio read is the PowerShell 5.1 WinRT dance: reflect out the
-- IAsyncOperation AsTask bridge, project the Radio type, block on
-- GetRadiosAsync. The sh layer owns the single quotes, so every PS
-- string is double-quoted; the literal backtick in the CLR generic name
-- IAsyncOperation`1 is doubled (the double-quoted-string escape for a
-- backtick) so exactly one reaches the comparison.
local pnp_cmd = "powershell.exe -NoProfile -Command '"
  .. '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
  .. '$d = Get-PnpDevice -Class Bluetooth; '
  .. '$d | Where-Object { $_.InstanceId -match "^BTHENUM.DEV_|^BTHLE.DEV_" -and $_.FriendlyName } '
  .. '| ForEach-Object { "dev|$($_.FriendlyName)" }; '
  .. 'Add-Type -AssemblyName System.Runtime.WindowsRuntime; '
  .. '$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() '
  .. '| Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 '
  .. '-and $_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation``1" })[0]; '
  .. '$null = [Windows.Devices.Radios.Radio,Windows.Devices.Radios,ContentType=WindowsRuntime]; '
  .. '$op = [Windows.Devices.Radios.Radio]::GetRadiosAsync(); '
  .. '$task = $asTaskGeneric.MakeGenericMethod([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]]).Invoke($null, @($op)); '
  .. 'if (-not $task.Wait(5000)) { "state|Unknown" } else { '
  .. '$bt = $task.Result | Where-Object Kind -eq "Bluetooth" | Select-Object -First 1; '
  .. 'if ($bt) { "state|$($bt.State)" } else { "state|none" } }'
  .. "'"

local bt_logo = icons.bluetooth

-- Device-type glyphs inferred from the FriendlyName. Segoe Fluent (via
-- the engine icon map) has no trackpad or phone glyph — those types fall
-- back to the Bluetooth logo.
local type_icons = {
  headset  = "sf:headphones",
  keyboard = "sf:keyboard",
  speaker  = "sf:speaker.wave.2",
}

local function infer_dtype(name)
  local n = name:lower()
  if n:match("airpod") or n:match("headphone") or n:match("headset")
    or n:match("buds") then
    return "headset"
  elseif n:match("keyboard") then
    return "keyboard"
  elseif n:match("speaker") then
    return "speaker"
  end
  return "generic"
end

-- ── Bar pill ────────────────────────────────────────────────────────────────
local bt_icon = sbar.add("item", "widgets.bluetooth", {
  position = "right",
  icon = {
    string = bt_logo,
    font = { size = 13 },
    color = colors.blue,
    padding_left = 7,
    padding_right = 7,
  },
  label = { drawing = false },
  padding_left = 2,
  padding_right = 2,
})

local bt_bracket = sbar.add("bracket", "widgets.bluetooth.bracket", { bt_icon.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 26 },
})

sbar.add("item", "widgets.bluetooth.padding", {
  position = "right",
  width = settings.group_paddings,
})

local popup_pos = "popup." .. bt_bracket.name

-- ── Header: "Bluetooth" + radio toggle (click opens the Bluetooth
-- settings page) ───────────────────────────────────────────────────────────
local header = sbar.add("item", "widgets.bluetooth.popup.header", {
  position = popup_pos,
  width = popup_width,
  -- Item-level align defaults to center, and the fixed icon+label slots fill
  -- the row exactly — so any transient extra advance (the probe spinner's
  -- image) turns the centering slack negative and shifts the whole header
  -- left while a probe runs. Left-align the item so the slack never applies.
  align = "left",
  icon = {
    string = "Bluetooth",
    align = "left",
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = icons.switch.on,
    align = "right",
    -- Literal Segoe Fluent toggle glyph — needs the explicit family (only
    -- sf: strings auto-select the icon font).
    font = { family = icons.switch.font, size = 16 },
    color = colors.blue,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -13 },
})

-- Shown only when WinRT enumerates no Bluetooth radio at all (macOS used
-- this slot for the blueutil TCC-denied notice; Windows has no TCC).
local access_row = sbar.add("item", "widgets.bluetooth.access", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    string = "No Bluetooth radio found",
    align = "left",
    color = colors.grey,
    font = { size = 10.5 },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = "Open Settings",
    align = "right",
    color = colors.white,
    font = { size = 10.5, style = settings.font.style_map["Semibold"] },
    width = popup_width / 2,
    padding_right = inset,
  },
})

-- ── Device list: fixed row pool bound per probe (flyout body) ──────────────
-- Single-line rows, name only: per-device battery needs a
-- DEVPKEY_Bluetooth battery property read per device (and live Connected
-- state another) — skipped to keep this a single probe.
local dev_rows = {}
for i = 1, max_devices do
  dev_rows[i] = sbar.add("item", "widgets.bluetooth.dev." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    align = "left",
    icon = {
      string = bt_logo,
      color = colors.white,
      font = { size = 12.5 },
      width = 35,
      align = "center",
      padding_left = inset,
    },
    label = {
      string = "",
      color = colors.white,
      font = { size = 11.5 },
      width = popup_width - 35 - inset,
      align = "left",
    },
  })
end

-- Nearby Devices section dropped: Windows has no inquiry-scan or
-- pair-from-CLI surface (macOS used `blueutil --inquiry` / `--pair`);
-- discovery lives in ms-settings:bluetooth via the footer row.

-- ── Audio mixer ────────────────────────────────────────────────────────────
-- The system output slider, Windows-quick-settings style — the output is
-- usually the connected headset when this flyout is open. Same geometry as
-- the media popup's volume row (both popups are 264 wide), driven by the
-- same pair of flows: volume_change pushes in, ybar.volume(pct) out — one
-- in-process call, no shell round trip, no 2 % key quantization.
sbar.add("item", "widgets.bluetooth.mixer.sep", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local vol_slider = sbar.add("slider", "widgets.bluetooth.volume", 220, {
  position = popup_pos,
  width = popup_width,
  padding_left = 0,
  padding_right = 0,
  align = "left",
  icon = {
    string = "sf:speaker.wave.2.fill",
    color = colors.grey,
    font = { size = 9.5 },
    padding_left = inset,
    padding_right = 7,
  },
  label = { drawing = false },
  slider = {
    percentage = 50,
    highlight_color = colors.white,
    background = {
      height = 5,
      corner_radius = 3,
      color = colors.bg2,
    },
    knob = {
      string = "●", -- text bullet; Segoe Fluent Icons maps no circle glyph
      drawing = true,
    },
  },
})

-- Slider release delivers a plain mouse.clicked with PERCENTAGE (0-100).
vol_slider:subscribe("mouse.clicked", function(env)
  local pct = tonumber(env.PERCENTAGE or "")
  if not pct then return end
  -- Optimistic paint; the volume_change push from the set settles it.
  vol_slider:set({ slider = { percentage = pct } })
  ybar.volume(pct)
end)

vol_slider:subscribe("volume_change", function(env)
  local vol = tonumber(env.INFO)
  if not vol then return end
  vol_slider:set({ slider = { percentage = vol } })
end)

-- ── Footer: More Bluetooth settings ────────────────────────────────────────
sbar.add("item", "widgets.bluetooth.sep", {
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
    string = "More Bluetooth settings",
    align = "left",
    color = colors.white,
    font = { size = 10.5 },
    width = popup_width - inset,
    padding_left = inset,
  },
  label = { drawing = false },
})

-- ── State ──────────────────────────────────────────────────────────────────
local paired_cache = {}      -- { name, dtype }
local radio_state = "On"     -- last probe's WinRT power: On/Off/Disabled/none
local busy = false

-- Spinner beside "Bluetooth" while the probe runs (~1-2 s).
local spinner = require("helpers.spinner").attach(header)

-- ── Populate ───────────────────────────────────────────────────────────────
-- "Unknown" (a WinRT read that timed out) is NOT "off": the device nodes
-- still enumerated — they print before the radio line precisely so a slow
-- radio read can't suppress them — so only an explicit Off/Disabled/none
-- collapses the list and greys the pill.
local function radio_is_off()
  return radio_state == "Off" or radio_state == "Disabled" or radio_state == "none"
end

local function populate()
  local off = radio_is_off()
  header:set({
    label = {
      string = (not off) and icons.switch.on or icons.switch.off,
      -- Accent blue only when confirmed On; neutral white when Unknown.
      color = radio_state == "On" and colors.blue or (off and colors.grey or colors.white),
    },
  })
  access_row:set({ drawing = radio_state == "none" })

  -- Device rows whenever the radio isn't definitively off (the flyout body
  -- collapses to just the header when it is, like the native one).
  local row = 0
  if not off then
    for _, dev in ipairs(paired_cache) do
      if row < max_devices then
        row = row + 1
        local glyph = type_icons[dev.dtype]
        if not glyph then
          if dev.name:match("Watch") then
            glyph = "sf:applewatch"
          elseif dev.name:match("TV") then
            glyph = "sf:appletv"
          end
        end
        dev_rows[row]:set({
          drawing = true,
          icon = { string = glyph or bt_logo },
          label = { string = dev.name },
        })
      end
    end
  end
  for i = row + 1, max_devices do
    dev_rows[i]:set({ drawing = false })
  end
end

-- Bar icon reflects the radio power: blue when on, dim otherwise
-- (macOS also brightened on active connections — connected state is a
-- per-device property read on Windows, so the pill stays two-state).
local function apply_bar_icon()
  -- Grey only when definitively off; Unknown keeps the pill lit (devices
  -- enumerated), matching populate()'s device-visibility rule.
  bt_icon:set({
    icon = { color = radio_is_off() and colors.grey or colors.blue },
  })
end

-- ── Data refresh ───────────────────────────────────────────────────────────
-- The single PowerShell round trip: radio power + paired names.
local function refresh_paired()
  if busy then return end
  busy = true
  spinner.start()
  sbar.exec(pnp_cmd, function(output)
    busy = false
    spinner.stop()
    paired_cache = {}
    local seen = {}
    for line in string.gmatch(output or "", "[^\r\n]+") do
      local state = line:match("^state|(.+)$")
      if state then
        radio_state = state
      else
        local name = line:match("^dev|(.+)$")
        -- Classic (BTHENUM) and LE (BTHLE) nodes can both carry the same
        -- device — dedupe by name.
        if name and not seen[name] and #paired_cache < max_devices then
          seen[name] = true
          paired_cache[#paired_cache + 1] = {
            name = name,
            dtype = infer_dtype(name),
          }
        end
      end
    end
    populate()
    apply_bar_icon()
  end)
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function collapse_popup()
  bt_bracket:set({ popup = { drawing = false } })
end

local function open_bt_settings()
  sbar.exec('explorer.exe "ms-settings:bluetooth"')
  collapse_popup()
end

-- No non-admin CLI flips the radio — the toggle hands off to Settings.
header:subscribe("mouse.clicked", open_bt_settings)

access_row:subscribe("mouse.clicked", open_bt_settings)

-- No CLI connect/disconnect either — device rows hand off to Settings.
for i = 1, max_devices do
  dev_rows[i]:subscribe("mouse.clicked", open_bt_settings)
end

settings_row:subscribe("mouse.clicked", open_bt_settings)

local function toggle_popup()
  local should_draw = bt_bracket:query().popup.drawing == "off"
  if should_draw then
    bt_bracket:set({ popup = { drawing = true } })
    populate()      -- last snapshot first, then the fresh round trip
    refresh_paired()
  else
    collapse_popup()
  end
end

bt_icon:subscribe("mouse.clicked", toggle_popup)
bt_icon:subscribe("mouse.exited.global", collapse_popup)
bt_icon:subscribe("system_woke", refresh_paired)

refresh_paired()
