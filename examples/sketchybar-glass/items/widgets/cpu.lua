local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: system monitor popup in the Task Manager Performance style —
-- per-request, the arc gauges became rolling area graphs: a "CPU | n%"
-- header row, a bordered utilization graph, and the chip name under each.
-- WINDOWS: CPU comes from the native `system_stats` event env (CPU_USAGE,
-- pushed every 2 s) and its popup graph accumulates history even while
-- closed, so it opens pre-filled. GPU has no push source — while the popup
-- is open a 3 s PowerShell perf-counter poll sums the 3D-engine
-- utilization (the same figure Task Manager shows), so its graph fills
-- while open. Chip/adapter names come from one WMI probe on popup open.

local popup_width = 211
local inset = 11

-- ── Bar item: CPU load as a progress bar ──────────────────────────────────
-- The rolling history graph now lives only in the popup; the strip carries a
-- plain fill meter, which reads at a glance where 42px of history did not.
-- The popup still has the full graph and the exact percentage.
local cpu = sbar.add("slider", "widgets.cpu", 52, {
  position = "right",
  slider = {
    percentage = 0,
    -- Read-only meter: without this a mouse-down rewrites the percentage from
    -- the pointer x, so the pill would show a fabricated load (see
    -- battery.lua, where exactly that shipped).
    interactive = false,
    highlight_color = colors.blue,
    background = {
      height = 9,
      corner_radius = 5, -- half the height: fully rounded ends
      color = colors.with_alpha(colors.white, 0.10), -- empty body
    },
    knob = { drawing = false },
  },
  -- No padding_left here: the pill's left margin comes from the bracket below,
  -- so that both sides are set by one number. padding_right is the gap between
  -- the glyph and the meter, not a pill margin.
  icon = { string = icons.cpu, padding_left = 0, padding_right = 7 },
  label = { drawing = false },
  -- These MUST match the bracket's padding below. The pill is drawn at
  -- content box + BRACKET padding while the item box is content box + ITEM
  -- padding, so any difference is pill overhanging item, and it comes
  -- straight out of the gap to the neighbour: at the previous value of 2
  -- against a bracket 9 the CPU pill overhung by 7 and ended up 1pt ON TOP of
  -- the wifi pill. Equal values make pill edge == item edge, which leaves the
  -- inter-pill gap equal to the spacer item alone, like every other pill.
  padding_left = 9,
  padding_right = 9
})

local cpu_bracket = sbar.add("bracket", "widgets.cpu.bracket", { cpu.name }, {
  background = { color = colors.mica }, -- tint over the Mica material
  -- Inner pill margin, and the ONLY lever that can put one on the right: a
  -- pill is sized from its members' content boxes plus the BRACKET's padding,
  -- so item padding lands outside the pill entirely. The icon supplies its own
  -- left margin, a slider has none, so without this the meter ran straight
  -- into the pill's rounded edge. Matches battery, the other slider pill.
  padding_left = 9,
  padding_right = 9,
  -- No fixed popup row height: gauge tiles size to their content.
  popup = { align = "center" }
})

require("helpers.hover").pill(cpu_bracket, cpu)

-- ── Popup: Task Manager-style graph dashboard ─────────────────────────────
local popup_pos = "popup." .. cpu_bracket.name

local header = sbar.add("item", "widgets.cpu.popup.header", {
  position = popup_pos,
  width = popup_width,
  align = "center",
  icon = {
    string = "System Monitor",
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
  },
  label = { drawing = false },
})

-- Section header, Task Manager style: name left, live percentage right.
local function add_section_title(name)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      string = name,
      align = "left",
      font = { size = 11.5, style = settings.font.style_map["Bold"] },
      width = popup_width / 2,
      padding_left = inset,
    },
    label = {
      string = "…",
      align = "right",
      font = {
        family = settings.font.numbers,
        size = 11.5,
        style = settings.font.style_map["Semibold"],
      },
      color = colors.white,
      width = popup_width / 2,
      padding_right = inset,
    },
    padding_top = 5,
  })
end

-- Rolling utilization graph in a bordered box: thin line over a soft area
-- fill, one point per sample.
local graph_points = popup_width - 2 * inset

local function add_history_graph(name)
  return sbar.add("graph", name, graph_points, {
    position = popup_pos,
    graph = {
      color = colors.blue,
      fill_color = colors.with_alpha(colors.blue, 0.18),
      line_width = 1.5,
    },
    background = {
      height = 56,
      color = colors.with_alpha(colors.white, 0.03),
      border_color = colors.with_alpha(colors.grey, 0.4),
      border_width = 1,
      drawing = true,
    },
    icon = { drawing = false },
    label = { drawing = false },
    padding_left = inset,
    padding_right = inset,
  })
end

local function add_center(text, opts)
  opts = opts or {}
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    align = "center",
    icon = {
      string = text,
      color = opts.color or colors.white,
      font = {
        size = opts.size or 11.5,
        style = settings.font.style_map[opts.style or "Semibold"],
      },
    },
    label = { drawing = false },
  })
end

local function add_separator()
  sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = { drawing = false },
    label = { drawing = false },
    background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
  })
end

-- YBAR PORT: section titles lose their inline glyph (macOS concatenated the
-- literal SF-Symbols character into the text; Windows `sf:` references must
-- be the whole icon string, so they cannot be embedded mid-text).
add_separator()
local cpu_title = add_section_title("CPU")
local cpu_hist  = add_history_graph("widgets.cpu.hist")
local cpu_chip  = add_center("…", { color = colors.grey, size = 9.5, style = "Regular" })
add_separator()
local gpu_title = add_section_title("GPU")
local gpu_hist  = add_history_graph("widgets.gpu.hist")
local gpu_chip  = add_center("…", { color = colors.grey, size = 9.5, style = "Regular" })

-- ── Helpers ───────────────────────────────────────────────────────────────
local function cpu_color_for(load)
  if load > 80 then return colors.red
  elseif load > 60 then return colors.orange
  elseif load > 30 then return colors.yellow
  else return colors.blue
  end
end

-- Last system_stats env, so a freshly opened popup paints immediately
-- instead of waiting for the next 2 s tick.
local last_stats = nil

local function update_popup_from_stats(env)
  local load = tonumber(env.CPU_USAGE) or 0
  cpu_title:set({
    label = { string = load .. "%", color = cpu_color_for(load) },
  })
end

local gpu_gen = 0 -- bumping cancels the in-flight GPU poll loop

local function hide_popup()
  gpu_gen = gpu_gen + 1
  cpu_bracket:set({ popup = { drawing = false } })
end

-- One WMI probe per popup open: CPU name | GPU adapter name.
local probe_cmd = "powershell.exe -NoProfile -Command '"
  .. '$cpu=((Get-CimInstance Win32_Processor).Name | Select-Object -First 1); '
  .. '$gpu=((Get-CimInstance Win32_VideoController).Name | Select-Object -First 1); '
  .. 'Write-Output ($cpu.Trim()+"|"+$gpu.Trim())'
  .. "'"

-- GPU utilization: sum of the 3D-engine perf counters — the figure Task
-- Manager reports. Get-Counter samples for ~1 s, so it runs async and only
-- while the popup is open (a generation counter cancels a stale loop).
local gpu_cmd = "powershell.exe -NoProfile -Command '"
  .. "$s=((Get-Counter \"\\GPU Engine(*engtype_3D)\\Utilization Percentage\" "
  .. "-ErrorAction SilentlyContinue).CounterSamples "
  .. "| Measure-Object CookedValue -Sum).Sum; "
  .. 'Write-Output ([math]::Round([math]::Min(100, [double]$s)))'
  .. "'"

local function poll_gpu(gen)
  if gen ~= gpu_gen then return end
  sbar.exec(gpu_cmd, function(out)
    if gen ~= gpu_gen then return end
    local pct = tonumber((out or ""):match("(%d+)"))
    if pct then
      gpu_hist:push({ pct / 100. })
      gpu_title:set({
        label = { string = pct .. "%", color = cpu_color_for(pct) },
      })
    end
    sbar.delay(3, function() poll_gpu(gen) end)
  end)
end

local function refresh_popup()
  sbar.exec(probe_cmd, function(out)
    local chip, gpu = (out or ""):match("^%s*(.-)%s*|%s*(.-)%s*$")
    if chip and chip ~= "" then cpu_chip:set({ icon = { string = chip } }) end
    if gpu and gpu ~= "" then gpu_chip:set({ icon = { string = gpu } }) end
    if last_stats then update_popup_from_stats(last_stats) end
  end)
end

-- The native system_stats event repaints the CPU gauge every 2 s while
-- open; the GPU poll runs its own 3 s loop, ended by generation bump.
local function toggle_popup()
  local should_draw = cpu_bracket:query().popup.drawing == "off"
  if should_draw then
    cpu_bracket:set({ popup = { drawing = true } })
    if last_stats then update_popup_from_stats(last_stats) end
    refresh_popup()
    gpu_gen = gpu_gen + 1
    poll_gpu(gpu_gen)
  else
    hide_popup()
  end
end

-- ── Events ────────────────────────────────────────────────────────────────
cpu:subscribe("system_stats", function(env)  -- YBAR PORT: built-in provider
  local load = tonumber(env.CPU_USAGE) or 0
  -- The popup graph samples continuously (2 s cadence), so it opens with
  -- history already on screen — Task Manager behavior.
  cpu_hist:push({ load / 100. })

  -- Glide the meter instead of stepping it. Samples land every 2 s, so an
  -- un-eased set makes the fill teleport; over 10 frames it reads as a trend.
  -- Well inside the sample interval, so the pump stops between samples and
  -- the bar still does no GPU work at rest.
  sbar.animate("sin", 10, function()
    cpu:set({ slider = { percentage = load, highlight_color = cpu_color_for(load) } })
  end)

  last_stats = env
  if cpu_bracket:query().popup.drawing == "on" then
    update_popup_from_stats(env)
  end
end)

header:subscribe("mouse.clicked", function()
  sbar.exec("taskmgr.exe")  -- YBAR PORT: Activity Monitor → Task Manager
  hide_popup()
end)


cpu:subscribe("mouse.clicked", toggle_popup)
cpu:subscribe("mouse.exited.global", hide_popup)

sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings
})
