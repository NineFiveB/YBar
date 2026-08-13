local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: system monitor popup in the Stats-app dashboard style:
-- arc gauges (YBar's gauge component) for CPU and memory, plus a disk
-- gauge and an uptime row — each tile a stack of centered rows.
-- WINDOWS: all live numbers come from the native `system_stats` event env
-- (CPU_USAGE, MEMORY_USAGE/MEMORY_FRACTION, DISK_FREE_GB/DISK_TOTAL_GB)
-- pushed every 2 s — helpers/system_stats_rich.sh is gone. Static facts
-- (CPU name, total RAM, uptime) come from one PowerShell exec on popup
-- open. Network throughput rows are dropped: no byte-counter helper here.

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
local mem_gauge   = add_gauge()
add_center("MEMORY")
local mem_detail  = add_center("…", { color = colors.grey, size = 11, style = "Regular" })
add_separator()
local disk_gauge  = add_gauge()
add_center("DISK")
local disk_detail = add_center("…", { color = colors.grey, size = 11, style = "Regular" })
add_separator()
add_center("UPTIME")
local uptime_row  = add_center("…", { color = colors.grey, size = 11, style = "Regular" })

-- ── Helpers ───────────────────────────────────────────────────────────────
local function cpu_color_for(load)
  if load > 80 then return colors.red
  elseif load > 60 then return colors.orange
  elseif load > 30 then return colors.yellow
  else return colors.blue
  end
end

local function fmt_size(gb)
  if not gb then return "—" end
  if gb >= 1000 then return string.format("%.1f TB", gb / 1000) end
  if gb >= 10 then return string.format("%.0f GB", gb) end
  if gb >= 1 then return string.format("%.1f GB", gb) end
  return string.format("%.0f MB", gb * 1000)
end

-- Last system_stats env, so a freshly opened popup paints immediately
-- instead of waiting for the next 2 s tick.
local last_stats = nil
-- Total RAM in GB, learned from the PowerShell probe on popup open; lets
-- mem_detail show "used of total" from MEMORY_FRACTION alone.
local mem_total_gb = nil

local function update_popup_from_stats(env)
  local load = tonumber(env.CPU_USAGE) or 0
  cpu_gauge:set({
    gauge = { percentage = load, color = cpu_color_for(load) },
    label = load .. "%",
  })

  local mem_pct = tonumber(env.MEMORY_USAGE) or 0
  mem_gauge:set({
    gauge = { percentage = mem_pct, color = cpu_color_for(mem_pct) },
    label = mem_pct .. "%",
  })
  local frac = tonumber(env.MEMORY_FRACTION)
  if frac and mem_total_gb then
    mem_detail:set({
      icon = { string = fmt_size(frac * mem_total_gb) .. " of " .. fmt_size(mem_total_gb) },
    })
  end

  local free_gb = tonumber(env.DISK_FREE_GB)
  local total_gb = tonumber(env.DISK_TOTAL_GB)
  if free_gb and total_gb and total_gb > 0 then
    local pct = math.floor((total_gb - free_gb) / total_gb * 100 + 0.5)
    disk_gauge:set({
      gauge = { percentage = pct, color = cpu_color_for(pct) },
      label = pct .. "%",
    })
    disk_detail:set({
      icon = { string = fmt_size(free_gb) .. " free of " .. fmt_size(total_gb) },
    })
  end
end

local function hide_popup()
  cpu_bracket:set({ popup = { drawing = false } })
end

-- One PowerShell probe per popup open: CPU name, total RAM (GB), uptime.
-- Prints a single compact line "Name|GB|Xd Yh Zm" parsed with Lua patterns.
local probe_cmd = "powershell.exe -NoProfile -Command '"
  .. '$os=Get-CimInstance Win32_OperatingSystem; '
  .. '$cpu=((Get-CimInstance Win32_Processor).Name | Select-Object -First 1); '
  .. '$up=(Get-Date)-$os.LastBootUpTime; '
  .. '$mem=[math]::Round($os.TotalVisibleMemorySize/1048576,1); '
  .. 'Write-Output ($cpu.Trim()+"|"+$mem+"|"+$up.Days+"d "+$up.Hours+"h "+$up.Minutes+"m")'
  .. "'"

local function refresh_popup()
  sbar.exec(probe_cmd, function(out)
    local chip, total, up = (out or ""):match("^%s*(.-)%s*|%s*([%d%.]+)%s*|%s*(.-)%s*$")
    if chip and chip ~= "" then cpu_chip:set({ icon = { string = chip } }) end
    mem_total_gb = tonumber(total)
    if up then uptime_row:set({ icon = { string = up } }) end
    if last_stats then update_popup_from_stats(last_stats) end
  end)
end

-- YBAR PORT: no 3 s helper-script polling loop — the native system_stats
-- event repaints the open popup every 2 s; only the static probe runs on
-- open.
local function toggle_popup()
  local should_draw = cpu_bracket:query().popup.drawing == "off"
  if should_draw then
    cpu_bracket:set({ popup = { drawing = true } })
    if last_stats then update_popup_from_stats(last_stats) end
    refresh_popup()
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
