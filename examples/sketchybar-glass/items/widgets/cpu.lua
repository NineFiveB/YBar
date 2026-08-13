local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: system monitor popup in the Stats-app dashboard style —
-- two arc gauges (YBar's gauge component): CPU and GPU. The memory/disk
-- gauges and the uptime row of the earlier layout were removed by request.
-- WINDOWS: CPU comes from the native `system_stats` event env (CPU_USAGE,
-- pushed every 2 s). GPU has no push source — while the popup is open a
-- 3 s PowerShell perf-counter poll sums the 3D-engine utilization (the
-- same figure Task Manager shows). Chip/adapter names come from one WMI
-- probe on popup open.

local popup_width = 240
local inset = 12

-- ── Bar item: small CPU graph in the menu bar ─────────────────────────────
local cpu = sbar.add("graph", "widgets.cpu", 42, {
  position = "right",
  graph = { color = colors.blue },
  background = {
    height = 22,
    color = { alpha = 0 },
    border_color = { alpha = 0 },
    drawing = true,
  },
  icon = { string = icons.cpu },
  label = {
    string = "cpu ??%",
    font = {
      family = settings.font.numbers,
      style = settings.font.style_map["Bold"],
      size = 9.0,
    },
    align = "right",
    padding_right = 0,
    width = 0,
    y_offset = 4
  },
  padding_right = settings.paddings + 6
})

local cpu_bracket = sbar.add("bracket", "widgets.cpu.bracket", { cpu.name }, {
  background = { color = colors.bg1 },
  -- No fixed popup row height: gauge tiles size to their content.
  popup = { align = "center" }
})

-- ── Popup: gauge dashboard ────────────────────────────────────────────────
local popup_pos = "popup." .. cpu_bracket.name

local header = sbar.add("item", "widgets.cpu.popup.header", {
  position = popup_pos,
  width = popup_width,
  align = "center",
  icon = {
    string = "System Monitor",
    font = { size = 14, style = settings.font.style_map["Bold"] },
  },
  label = { drawing = false },
})

local function add_gauge()
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    align = "center",
    icon = { drawing = false },
    gauge = {
      percentage = 0,
      size = 84,
      thickness = 8,
      color = colors.blue,
      track_color = colors.with_alpha(colors.grey, 0.25),
    },
    label = {
      string = "…",
      font = { size = 19, style = settings.font.style_map["Semibold"] },
      color = colors.white,
    },
    padding_top = 6,
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
        size = opts.size or 13,
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
local cpu_gauge   = add_gauge()
add_center("CPU LOAD")
local cpu_chip    = add_center("…", { color = colors.grey, size = 11, style = "Regular" })
add_separator()
local gpu_gauge   = add_gauge()
add_center("GPU LOAD")
local gpu_chip    = add_center("…", { color = colors.grey, size = 11, style = "Regular" })

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
  cpu_gauge:set({
    gauge = { percentage = load, color = cpu_color_for(load) },
    label = load .. "%",
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
      gpu_gauge:set({
        gauge = { percentage = pct, color = cpu_color_for(pct) },
        label = pct .. "%",
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
  cpu:push({ load / 100. })

  local color = cpu_color_for(load)

  cpu:set({
    graph = { color = color },
    label = "cpu " .. load .. "%",
  })

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
