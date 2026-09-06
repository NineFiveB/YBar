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
  background = { color = colors.mica }, -- tint over the Mica material
  -- wrap_width turns the popup into flow layout so the volume row can seat
  -- two items on one line (slider + mixer chevron, and the mixer panel's
  -- icon + slider pairs). It is popup_width + 4 and NOT popup_width: the
  -- engine's line advance is padding_left + width + padding_right, and every
  -- full-width row inherits the theme default item paddings (2/2), so rows
  -- advance 268. 268 also reproduces the no-wrap panel exactly (widest
  -- advance 268 + 2x6 engine inset = 280 wide), pixel-identical to before.
  popup = { align = "center", height = 26, wrap_width = popup_width + 4 },
})

require("helpers.hover").pill(bt_bracket, bt_icon)

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
  require("helpers.hover").row(dev_rows[i])
end

-- Nearby Devices section dropped: Windows has no inquiry-scan or
-- pair-from-CLI surface (macOS used `blueutil --inquiry` / `--pair`);
-- discovery lives in ms-settings:bluetooth via the footer row.

-- ── Audio mixer ────────────────────────────────────────────────────────────
-- The system output slider, Windows-quick-settings style, with the
-- quick-settings chevron beside it: the chevron swaps the row for the
-- per-app volume mixer (one slider per audio-session group from
-- `--query audio`), exactly like pressing the chevron next to the Windows 11
-- volume slider. Master flows: volume_change pushes in, ybar.volume(pct)
-- out; per-app rows call ybar.volume(pct, id) — all in-process, no shell
-- round trip, no 2 % key quantization.
--
-- Line arithmetic (engine advance = padding_left + width + padding_right,
-- line cap = wrap_width 268): master row = slider 232 (paddings 0) + chevron
-- 32 (default paddings 2/2, advance 36) = 268 — the chevron's right edge
-- lands at the same x as every full-width row's. Mixer rows = icon 35
-- (paddings 2/0, advance 37, content starting at x=2 like the device rows)
-- + slider 229 (paddings 0) = 266. The mixer-open back row is the same
-- chevron item restyled to full width (advance 268, its own line).
sbar.add("item", "widgets.bluetooth.mixer.sep", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local vol_slider = sbar.add("slider", "widgets.bluetooth.volume", 188, {
  position = popup_pos,
  width = popup_width - 32,
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
      -- 18pt makes the knob a 16px circle at 2x (vs the 10px track), the
      -- Windows-slider look — at the default 11.5 the ink was flush with
      -- the filled track and vanished at 100%.
      font = { size = 18 },
      -- The knob em-centres like every text part (reference math), but the
      -- Segoe bullet's ink sits low in its em, and the sag grows with the
      -- font size (not quite linearly): 1.25pt centred it at 11.5pt,
      -- 2.25pt centres it at 18pt to the pixel (validated held-open sweep,
      -- 2026-09-02). macOS never showed this: the SF circle's ink is
      -- symmetric in its em.
      y_offset = 2.25,
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

-- The chevron: collapsed it is a 32-wide button sharing the master slider's
-- line; open_mixer() restyles it into the panel's full-width back row
-- (chevron.left + "Volume mixer"), which is also what keeps the flow layout
-- sane — a 32-wide row with the slider hidden would let the first app icon
-- join its line and stagger every pair after it.
local mixer_btn = sbar.add("item", "widgets.bluetooth.mixer.btn", {
  position = popup_pos,
  align = "left",
  width = 32,
  icon = {
    string = "sf:chevron.right",
    color = colors.grey,
    font = { size = 10.5 },
    width = 32,
    align = "center",
    padding_left = 0,
    padding_right = 0,
  },
  label = {
    drawing = false,
    string = "Volume mixer",
    align = "left",
    color = colors.white,
    font = { size = 10.5, style = settings.font.style_map["Semibold"] },
    width = popup_width - 35 - inset,
  },
})

-- ── Per-app mixer panel: fixed pool, hidden until the chevron opens it ─────
-- Each row is TWO items (icon, then slider) sharing a wrapped line. The app
-- icon deliberately lives OUTSIDE the slider item: the engine maps any
-- click inside a slider item to a track position clamped to 0-100
-- (reference parity), so an icon inside the slider would set the app's
-- volume to zero when clicked. A separate item is inert.
local MAX_MIX = 8
local mix_icons, mix_sliders, mix_ids = {}, {}, {}
for i = 1, MAX_MIX do
  mix_icons[i] = sbar.add("item", "widgets.bluetooth.mix.icon." .. i, {
    position = popup_pos,
    drawing = false,
    width = 35,
    padding_left = 2, -- line the glyph column up with the device rows
    padding_right = 0,
    icon = {
      -- Glyph face for the "system" group (system sounds have no exe icon);
      -- app groups swap to the image part instead.
      string = "sf:speaker.wave.2",
      color = colors.grey,
      font = { size = 12.5 },
      width = 35,
      align = "center",
      padding_left = 0,
      padding_right = 0,
      drawing = false,
    },
    label = { drawing = false },
    image = { drawing = false, size = 16 },
  })
  mix_sliders[i] = sbar.add("slider", "widgets.bluetooth.mix." .. i, 190, {
    position = popup_pos,
    drawing = false,
    width = popup_width - 35,
    padding_left = 0,
    padding_right = 0,
    align = "left",
    icon = { drawing = false },
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
        string = "●", -- same face, size and lift as the master knob
        font = { size = 18 },
        y_offset = 2.25,
        drawing = true,
      },
    },
  })
end

local mix_empty = sbar.add("item", "widgets.bluetooth.mix.empty", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    string = "Nothing is playing audio",
    align = "left",
    color = colors.grey,
    font = { size = 10.5 },
    width = popup_width - inset,
    padding_left = inset,
  },
  label = { drawing = false },
})

local mixer_open = false
local mix_gen = 0 -- bumped on every open/close; stale poll closures bail

-- Bind the pool to the current session groups. Re-sets BOTH faces every
-- time: a row can flip identity between an app (image) and the system
-- group (glyph) across binds.
local function bind_mixer()
  -- Drop apps that are merely RESIDENT: still running and still holding an
  -- audio session, but with no window and playing nothing. Closing the Xbox
  -- app leaves XboxPcApp.exe alive with a live Inactive session, and a row for
  -- it is indistinguishable from the mixer having failed to refresh.
  --
  -- `active` comes first deliberately: anything actually producing sound stays
  -- listed even with no window, because that is exactly the row you would come
  -- here to mute.
  local groups = {}
  for _, g in ipairs(ybar.query_table("audio") or {}) do
    if g.active or not g.background then groups[#groups + 1] = g end
  end
  local shown = 0
  for i = 1, MAX_MIX do
    local g = groups[i]
    if g then
      shown = shown + 1
      mix_ids[i] = g.id
      if g.id == "system" then
        mix_icons[i]:set({
          drawing = true,
          icon = { drawing = true },
          image = { drawing = false },
        })
      else
        mix_icons[i]:set({
          drawing = true,
          icon = { drawing = false },
          -- Inactive groups (paused players) grey out via the desaturate
          -- shader flag, the apps-popup idiom.
          image = { drawing = true, string = "exe." .. g.path, desaturate = not g.active },
        })
      end
      -- Mid-drag sets are vetoed by the engine, so a poll landing during a
      -- drag cannot fight the knob.
      mix_sliders[i]:set({ drawing = true, slider = { percentage = g.volume } })
    else
      mix_ids[i] = nil
      mix_icons[i]:set({ drawing = false })
      mix_sliders[i]:set({ drawing = false })
    end
  end
  mix_empty:set({ drawing = shown == 0 })
end

-- 1 Hz refresh while the panel is open (the wifi scan-loop idiom): catches
-- sessions appearing/dying and volumes changed elsewhere. Guards: the
-- generation kills stale closures from a close-reopen inside one second,
-- and popup.drawing is a STRING ("on"/"off").
local function mixer_poll()
  local gen = mix_gen
  sbar.delay(1, function()
    if gen ~= mix_gen or not mixer_open then return end
    if bt_bracket:query().popup.drawing ~= "on" then return end
    bind_mixer()
    mixer_poll()
  end)
end

local function open_mixer()
  mix_gen = mix_gen + 1
  mixer_open = true
  vol_slider:set({ drawing = false })
  mixer_btn:set({
    width = popup_width,
    icon = { string = "sf:chevron.left", width = 35 },
    label = { drawing = true },
  })
  bind_mixer()
  mixer_poll()
end

local function close_mixer()
  mix_gen = mix_gen + 1
  mixer_open = false
  for i = 1, MAX_MIX do
    mix_icons[i]:set({ drawing = false })
    mix_sliders[i]:set({ drawing = false })
  end
  mix_empty:set({ drawing = false })
  vol_slider:set({ drawing = true })
  mixer_btn:set({
    width = 32,
    icon = { string = "sf:chevron.right", width = 32 },
    label = { drawing = false },
  })
end

mixer_btn:subscribe("mouse.clicked", function()
  if mixer_open then close_mixer() else open_mixer() end
end)

for i = 1, MAX_MIX do
  mix_sliders[i]:subscribe("mouse.clicked", function(env)
    local pct = tonumber(env.PERCENTAGE or "")
    local id = mix_ids[i]
    if not pct or not id then return end
    -- Optimistic paint; the next 1 Hz bind settles on the real value.
    mix_sliders[i]:set({ slider = { percentage = pct } })
    ybar.volume(pct, id)
  end)
end

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

require("helpers.hover").row(settings_row)

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
  -- Reopen always shows the master view. Guarded: mouse.exited.global lands
  -- here on every bar hover-exit, and close_mixer() is ~20 property sets —
  -- a stale-true flag after a silent engine close still passes, and the
  -- never-opened common case pays nothing.
  if mixer_open then close_mixer() end
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
    -- The engine can close this popup silently (auto-close on a bar press
    -- elsewhere runs no Lua), so the collapse-side reset is not enough —
    -- reset to the master view on the way in too.
    close_mixer()
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
