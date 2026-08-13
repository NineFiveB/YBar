local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- YBAR PORT: Bluetooth popup mimicking macOS Settings > Bluetooth:
-- header row, My Devices as two-line cells (name, then status), and a
-- Settings footer.
--
-- WINDOWS PORT: blueutil does not exist and Windows ships no supported
-- CLI for toggling the radio, connecting, pairing, or inquiry scans —
-- every "action" click deep-links into explorer.exe
-- "ms-settings:bluetooth" instead. State comes from a single PowerShell
-- `Get-PnpDevice -Class Bluetooth` probe run once at load and once per
-- popup open (no continuous polling): a Status-OK radio node lights the
-- pill, and the paired-device rows fill from the same query's
-- FriendlyName per BTHENUM/BTHLE device node. Per-device battery and
-- live Connected/Not Connected state are dropped — both need per-device
-- DEVPKEY property reads (extra round trips per device), so the status
-- line shows "Paired". The Nearby Devices section (inquiry scan +
-- pair-on-click) is dropped entirely: no inquiry CLI on Windows.

local popup_width = 320
local inset = 12
local max_devices = 6

-- One probe, compact output parsed in Lua:
--   radio|1        (a non-BTHENUM Status-OK node = the physical radio)
--   dev|<name>     (one line per paired device node)
local pnp_cmd = "powershell.exe -NoProfile -Command '"
  .. '$d = Get-PnpDevice -Class Bluetooth; '
  .. 'if ($d | Where-Object { $_.InstanceId -notmatch "^BTH" -and $_.Status -eq "OK" }) '
  .. '{ "radio|1" } else { "radio|0" }; '
  .. '$d | Where-Object { $_.InstanceId -match "^BTHENUM\\\\DEV_|^BTHLE\\\\DEV_" -and $_.FriendlyName } '
  .. '| ForEach-Object { "dev|$($_.FriendlyName)" }'
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
    font = { size = 15.0 },
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

-- ── Header: "Bluetooth" + power state (click opens Settings — Windows
-- has no supported CLI toggle) ─────────────────────────────────────────────
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
    string = icons.switch.on,
    align = "right",
    font = { size = 18 },
    color = colors.white,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

-- Shown only when no Bluetooth radio is present (macOS used this slot
-- for the blueutil TCC-denied notice; Windows has no TCC).
local access_row = sbar.add("item", "widgets.bluetooth.access", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    string = "No Bluetooth radio found",
    align = "left",
    color = colors.grey,
    font = { size = 12.0 },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = "Open Settings",
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
      padding_left = inset,
    },
    -- No label slot: the refresh spinner (image, align=r) trails the
    -- title directly; a fixed half-width label would push it past the
    -- row edge.
    label = { drawing = false },
    -- Content is title+spinner only; anchor it left like Settings.
    align = "left",
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
    align = "left",
    icon = {
      string = "",
      color = colors.white,
      font = { size = 13.0 },
      width = 44,
      align = "left",
      padding_left = 18,
    },
    label = {
      string = "",
      color = colors.white,
      font = { size = 13.0 },
      width = popup_width - 44 - inset,
      align = "left",
    },
  })
  paired_status_rows[i] = sbar.add("item", "widgets.bluetooth.devstatus." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    align = "left",
    icon = {
      string = "",
      color = colors.grey,
      font = { size = 11.0 },
      width = popup_width - 44,
      align = "left",
      padding_left = 44,
    },
    label = { drawing = false },
  })
end

-- Nearby Devices section dropped: Windows has no inquiry-scan or
-- pair-from-CLI surface (macOS used `blueutil --inquiry` / `--pair`);
-- discovery lives in ms-settings:bluetooth via the footer row.

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
  -- macOS put the gear glyph inline in the icon string; sf: names resolve
  -- whole strings, so the glyph is an sf. image and the text stands alone.
  image = { string = "sf.gearshape", size = 12, drawing = true, padding_left = inset },
  icon = {
    string = "Settings",
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = popup_width - 20 - inset,
    padding_left = 4,
  },
  label = { drawing = false },
})

-- ── State ──────────────────────────────────────────────────────────────────
local paired_cache = {}      -- { name, dtype }
local radio_present = true   -- Status-OK radio node in the last probe
local busy = false

-- Spinner beside "My Devices" while the PnP probe runs (~1-2 s).
local spinner = require("helpers.spinner").attach(my_header)

-- ── Populate ───────────────────────────────────────────────────────────────
local function populate()
  header:set({
    label = {
      string = radio_present and icons.switch.on or icons.switch.off,
      color = radio_present and colors.white or colors.grey,
    },
  })
  access_row:set({ drawing = not radio_present })

  local show = radio_present
  my_header:set({ drawing = show and #paired_cache > 0 })
  for i = 1, max_devices do
    local dev = show and paired_cache[i] or nil
    if dev then
      -- Per-device battery needs a DEVPKEY_Bluetooth battery property
      -- read per device (and live Connected state another) — skipped to
      -- keep this a single probe, so the status line is static.
      local status = "Paired"
      local glyph = type_icons[dev.dtype]
      if not glyph then
        if dev.name:match("Watch") then
          glyph = "sf:applewatch"
        elseif dev.name:match("TV") then
          glyph = "sf:appletv"
        end
      end
      paired_name_rows[i]:set({
        drawing = true,
        icon = {
          width = 44,
          string = glyph or bt_logo,
          font = { size = 13.0 },
        },
        label = { string = dev.name },
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
end

-- Bar icon reflects state: dim when no radio, blue when present
-- (macOS also brightened on active connections — connected state is a
-- per-device property read on Windows, so the pill stays two-state).
local function apply_bar_icon()
  bt_icon:set({
    icon = { color = radio_present and colors.blue or colors.grey },
  })
end

-- ── Data refresh ───────────────────────────────────────────────────────────
-- The single Get-PnpDevice round trip: radio presence + paired names.
local function refresh_paired(callback)
  if busy then return end
  busy = true
  spinner.start()
  sbar.exec(pnp_cmd, function(output)
    busy = false
    spinner.stop()
    paired_cache = {}
    local seen = {}
    for line in string.gmatch(output or "", "[^\r\n]+") do
      local radio = line:match("^radio|([01])")
      if radio then
        radio_present = radio == "1"
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
    if callback then callback() end
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

-- No CLI radio toggle on Windows — the header hands off to Settings.
header:subscribe("mouse.clicked", open_bt_settings)

access_row:subscribe("mouse.clicked", open_bt_settings)

-- No CLI connect/disconnect either — device rows hand off to Settings.
local function toggle_connection(i)
  if not paired_cache[i] then return end
  open_bt_settings()
end

for i = 1, max_devices do
  paired_name_rows[i]:subscribe("mouse.clicked", function() toggle_connection(i) end)
  paired_status_rows[i]:subscribe("mouse.clicked", function() toggle_connection(i) end)
end

settings_row:subscribe("mouse.clicked", open_bt_settings)

local function toggle_popup()
  local should_draw = bt_bracket:query().popup.drawing == "off"
  if should_draw then
    bt_bracket:set({ popup = { drawing = true } })
    populate()
    refresh_paired()
  else
    collapse_popup()
  end
end

bt_icon:subscribe("mouse.clicked", toggle_popup)
bt_icon:subscribe("mouse.exited.global", collapse_popup)
bt_icon:subscribe("system_woke", refresh_paired)

refresh_paired()
