local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: battery popup in the macOS style used across the other
-- widgets: "Battery" header with the percentage on the right, then
-- Power Source / Time Remaining / Condition / Max Capacity rows and a
-- Settings footer. The pill shows only the icon (percentage lives in
-- the popup). Maintenance, charge limit, low power mode, and current
-- status are gone — and with them the `battery` CLI dependency.
--
-- WINDOWS PORT: the pill is driven by the native battery_change /
-- power_source_change events (pmset is gone); the popup rows fill from
-- a single `Get-CimInstance Win32_Battery` round trip on open. The
-- slow update_freq is kept as a belt behind the events, and doubles as
-- the sampler for the Battery Level graph — Windows has no pmset-style
-- charge log to replay, so the graph fills from live samples while the
-- bar runs (216 buckets x 400 s = a rolling 24 h window once full).

local popup_width = 229
local inset = 11
local gear_col = inset + 15   -- Settings footer: inset + 11 pt glyph + 4 pt gap

-- The pill body is a slider so the charge fill is CONTINUOUS (smooth) rather
-- than 5 discrete SF-glyph levels: the slider track is the empty battery
-- body, the highlight fill is the charge fraction.
local battery = sbar.add("slider", "widgets.battery", 20, {
  position = "right",
  slider = {
    percentage = 100,
    -- Read-only meter: without this every mouse-down rewrites the percentage
    -- from the pointer x, so clicking the pill showed a fabricated charge
    -- (and a drag scrubbed it) until something re-applied the real value.
    interactive = false,
    highlight_color = colors.green,
    background = {
      height = 9,
      corner_radius = 2,
      color = colors.with_alpha(colors.white, 0.10),  -- empty body
    },
    knob = { drawing = false },
  },
  -- Both parts off: a slider item still carries an icon/label part, and the
  -- empty icon's advance would left-shift the track inside the bracket pill.
  icon = { drawing = false },
  label = { drawing = false },
  update_freq = 400,   -- belt behind the native events + graph sample cadence
  -- Equal padding = the body sits centered in the bracket pill; the track is
  -- auto-centered vertically (emitSlider centers on the row's mid-line).
  -- The pill's INNER margin comes from the bracket padding below (bracketFrame
  -- wraps the members' CONTENT boxes; a slider has no icon padding to supply
  -- margin). Item padding lands OUTSIDE the pill, so it must MATCH the bracket
  -- padding for the pill to reserve its full width in the flow and keep the
  -- inter-pill gaps uniform (spacer only).
  -- This was 8, one short of the bracket, to offset the calendar's leading
  -- spacer back when calendar was the pill after battery. The tray sits
  -- between them now, so the correction was being applied to the wrong gap
  -- and only made battery->tray 5pt against everyone else's 6.
  padding_left = 9,
  padding_right = 9,
})

local battery_bracket = sbar.add("bracket", "widgets.battery.bracket", { battery.name }, {
  background = { color = colors.mica }, -- tint over the Mica material
  -- Inner pill margin around the slider so the meter floats like the icon
  -- pills (whose margin comes from their icon padding, which a slider lacks).
  padding_left = 9,
  padding_right = 9,
  popup = { align = "center", height = 26 }
})

require("helpers.hover").pill(battery_bracket, battery)

local popup_pos = "popup." .. battery_bracket.name

-- ── Header: "Battery" + percentage ─────────────────────────────────────────
local header = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Battery",
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = "…",
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
    color = colors.white,
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -13 },
})

local function add_detail(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      align = "left",
      string = title,
      color = colors.grey,
      font = { size = 10.5 },
      width = popup_width / 2,
      padding_left = inset + 5,
    },
    label = {
      align = "right",
      string = "—",
      color = colors.grey,
      font = { size = 10.5, style = settings.font.style_map["Semibold"] },
      width = popup_width / 2,
      padding_right = inset,
    },
  })
end

-- Time Remaining, Condition and Max Capacity removed by request — the
-- estimate was mostly "No estimate" and the health rows have no cheap
-- Windows source (they were permanently em-dashed).
local power_source = add_detail("Power Source")

-- ── Battery Level graph (rolling 24 hours, sampled live) ───────────────────
-- Windows keeps no queryable charge history (pmset's log has no cheap
-- equivalent; powercfg /batteryreport is a heavyweight HTML export), so
-- the python helper is gone and the graph accumulates one sample per
-- routine tick instead. It starts empty and grows into the 24 h window.
local history_buckets = 216   -- 24h at 400 s per sample; 1pt per sample

sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Battery Level",
    color = colors.white,
    font = { size = 11.5, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = "Last 24 Hours",
    color = colors.grey,
    font = { size = 9.5 },
    width = popup_width / 2,
    padding_right = inset,
  },
  padding_top = 5,
})

local history = sbar.add("graph", "widgets.battery.history", history_buckets, {
  position = popup_pos,
  graph = { color = colors.green },
  background = {
    height = 56,
    color = { alpha = 0 },
    border_color = { alpha = 0 },
    drawing = true,
  },
  icon = { drawing = false },
  label = { drawing = false },
  padding_left = inset,
  padding_right = inset,
})

-- Breathing room UNDER the plot. The graph needs to clear the dim separator
-- below it (its zero-line is a near-white stroke along the box's bottom edge,
-- and the two otherwise read as one thick line) — but a y_offset lift moved
-- the box's TOP up too, so a 100% spike collided with the "Battery Level"
-- label. A spacer pushes the separator down instead, leaving both edges clear.
sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 8, color = colors.transparent, drawing = true },
})

local function push_history_sample(charge)
  if charge then history:push({ charge / 100 }) end
end

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
  -- macOS put the gear glyph inline in the icon string; sf: names resolve
  -- whole strings, so the glyph takes the icon part and the text the label.
  -- (An `sf.gearshape` image was tried first: the atlas has no sf. source,
  -- so it drew nothing but still reserved its width, indenting "Settings"
  -- past every other row's left edge.) Same padding as the header, so the
  -- gear's left edge lines up with "Battery" and "Battery Level".
  --
  -- Two slot rules bit the first attempt at this row. A part's fixed width
  -- REPLACES ink + paddings, so the inset has to fit inside it — a 16 pt
  -- slot with an 11 pt inset left 5 pt for an 11 pt glyph and clipped the
  -- gear to its left half. And an item centres its parts by default, so
  -- the two slots must sum to popup_width or the whole row drifts right by
  -- half the shortfall.
  icon = {
    string = "sf:gearshape",
    align = "left",
    color = colors.white,
    font = { size = 11 },
    width = gear_col,
    padding_left = inset,
  },
  label = {
    string = "Settings",
    align = "left",
    color = colors.white,
    font = { size = 10.5 },
    width = popup_width - gear_col,
  },
})

-- ── Updates ────────────────────────────────────────────────────────────────
local function hide_details()
  battery_bracket:set({ popup = { drawing = false } })
end

-- Last state pushed by the native events, so battery_change /
-- power_source_change can restyle the pill without any child process.
local last_charge = nil   -- 0-100
local on_ac = nil         -- true | false | nil (unknown)

local function apply_pill()
  -- Unknown charge (AC-only desktop with no reading) reads as full.
  local charge = last_charge or 100
  -- Monochrome theme: a dimmer fill flags a low battery in place of a colour.
  local fill = (charge <= 20 and not on_ac) and colors.grey or colors.green
  battery:set({ slider = { percentage = charge, highlight_color = fill } })
end

-- One Win32_Battery round trip: prints "level|status|runtime" (runtime in
-- minutes; empty, negative, or 71582788 = unknown). BatteryStatus 2/6/7/8/9
-- mean the machine is on AC.
local cim_cmd = "powershell.exe -NoProfile -Command '"
  .. '$b = Get-CimInstance Win32_Battery | Select-Object -First 1; '
  .. 'if ($b) { "$($b.EstimatedChargeRemaining)|$($b.BatteryStatus)|$($b.EstimatedRunTime)" }'
  .. "'"

local function refresh_from_cim(sample_history)
  sbar.exec(cim_cmd, function(out)
    local charge, status, runtime = out:match("(%d+)|(%d+)|(%-?%d*)")
    charge  = tonumber(charge)
    status  = tonumber(status)
    runtime = tonumber(runtime)

    if charge then last_charge = charge end
    if status then
      on_ac = status == 2 or status == 6 or status == 7
        or status == 8 or status == 9
    end

    apply_pill()
    if sample_history then push_history_sample(last_charge) end

    if battery_bracket:query().popup.drawing == "on" then
      header:set({ label = { string = charge and (charge .. "%") or "—" } })
      power_source:set({ label = on_ac and "Power Adapter" or "Battery" })
    end
  end)
end

local function update_main_icon(env)
  local sender = env and env.SENDER
  if sender == "battery_change" then
    last_charge = tonumber(env.INFO) or last_charge
    apply_pill()
  elseif sender == "power_source_change" then
    on_ac = env.INFO == "AC"
    apply_pill()
  else
    -- routine / forced / system_woke: full round trip; the routine tick is
    -- also the graph's sample clock.
    refresh_from_cim(sender == "routine")
  end
end

local function toggle_details()
  local should_draw = battery_bracket:query().popup.drawing == "off"
  if should_draw then
    battery_bracket:set({ popup = { drawing = true } })
    refresh_from_cim(false)
    -- no update_history(): the graph already holds the live-sampled window
  else
    hide_details()
    -- Belt: re-assert the real charge on close too, so the meter is correct
    -- even on an engine without slider.interactive (where the closing
    -- mouse-down would leave a pointer-derived percentage on screen).
    apply_pill()
  end
end

require("helpers.hover").row(settings_row)

settings_row:subscribe("mouse.clicked", function()
  sbar.exec('explorer.exe "ms-settings:batterysaver"')
  hide_details()
end)

battery:subscribe("mouse.clicked", toggle_details)
battery:subscribe("mouse.exited.global", hide_details)
battery:subscribe(
  { "routine", "battery_change", "power_source_change", "system_woke" },
  update_main_icon
)

sbar.add("item", "widgets.battery.padding", {
  position = "right",
  width = settings.group_paddings
})
