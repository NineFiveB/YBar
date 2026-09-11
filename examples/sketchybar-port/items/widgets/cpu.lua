local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: system monitor popup in the Stats-app dashboard style:
-- arc gauges (YBar's gauge component) for CPU and memory, disk with a
-- percentage + line, and live network throughput — each tile a stack of
-- centered rows. Data from helpers/system_stats_rich.sh; network rates
-- from successive byte-counter deltas. GPU is a rolling utilization graph
-- fed by the engine's system_stats env (GPU_USAGE, from the accelerator
-- driver) and appears only on a Mac whose driver reports one.

local stats_script = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/system_stats_rich.sh"

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
  -- No percentage on the pill: the original overlaid a "cpu n%" label on
  -- the graph through sketchybar's unclipped zero-width idiom, which YBar
  -- clips to the slot (a 0 pt slot draws nothing). The figure lives in the
  -- popup's gauge instead.
  label = { drawing = false },
  padding_right = settings.paddings + 6
})

local cpu_bracket = sbar.add("bracket", "widgets.cpu.bracket", { cpu.name }, {
  background = { color = colors.bg1 },
  -- No fixed popup row height: gauge tiles size to their content.
  popup = { align = "center" }
})

require("helpers.hover").pill(cpu_bracket, cpu)

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
    drawing = opts.drawing,
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

local function add_separator(opts)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    drawing = opts and opts.drawing,
    icon = { drawing = false },
    label = { drawing = false },
    background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
  })
end

add_separator()
local cpu_gauge   = add_gauge()
add_center(icons.cpu .. "  CPU LOAD")
local cpu_chip    = add_center("…", { color = colors.grey, size = 11, style = "Regular" })
add_separator()
local mem_gauge   = add_gauge()
add_center(icons.memory .. "  MEMORY")
local mem_detail  = add_center("…", { color = colors.grey, size = 11, style = "Regular" })

-- ── GPU: rolling utilization graph ────────────────────────────────────────
-- The engine publishes GPU_USAGE / GPU_FRACTION / GPU_MEMORY_USED_MB in the
-- system_stats env only when the accelerator driver reports a figure, so
-- this section starts hidden and appears on the first tick that carries
-- GPU_USAGE — a Mac with no readable counter keeps the two-gauge popup.
-- Windows cpu.lua's Task Manager idiom: name left, live percentage right,
-- then a bordered area graph that samples on EVERY tick, popup open or
-- not, so it opens with history already on screen.
local graph_points = popup_width - 2 * inset

local function add_section_title(name)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    drawing = false,
    icon = {
      string = name,
      align = "left",
      font = { size = 13, style = settings.font.style_map["Semibold"] },
      width = popup_width / 2,
      padding_left = inset,
    },
    label = {
      string = "…",
      align = "right",
      font = {
        family = settings.font.numbers,
        size = 13,
        style = settings.font.style_map["Semibold"],
      },
      color = colors.white,
      width = popup_width / 2,
      padding_right = inset,
    },
    padding_top = 6,
  })
end

local function add_history_graph(name)
  return sbar.add("graph", name, graph_points, {
    position = popup_pos,
    drawing = false,
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

local gpu_sep    = add_separator({ drawing = false })
local gpu_title  = add_section_title(icons.gpu .. "  GPU")
local gpu_hist   = add_history_graph("widgets.gpu.hist")
local gpu_detail = add_center("…", {
  color = colors.grey, size = 11, style = "Regular", drawing = false,
})

-- ── Helpers ───────────────────────────────────────────────────────────────
local function parse_system_stats(out)
  local stats = {}
  for line in string.gmatch(out or "", "[^\r\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k and v then stats[k] = v end
  end
  return stats
end

local function cpu_color_for(load)
  if load > 80 then return colors.red
  elseif load > 60 then return colors.orange
  elseif load > 30 then return colors.yellow
  else return colors.blue
  end
end

local function to_gb(str)
  local n, unit = (str or ""):match("^([%d%.]+)([KMGT])")
  n = tonumber(n)
  if not n then return nil end
  if unit == "T" then return n * 1000 end
  if unit == "M" then return n / 1000 end
  if unit == "K" then return n / 1000000 end
  return n
end

local function fmt_size(gb)
  if not gb then return "—" end
  if gb >= 1000 then return string.format("%.1f TB", gb / 1000) end
  if gb >= 10 then return string.format("%.0f GB", gb) end
  if gb >= 1 then return string.format("%.1f GB", gb) end
  return string.format("%.0f MB", gb * 1000)
end

local function update_popup_from_helper(out)
  local stats = parse_system_stats(out)

  cpu_chip:set({ icon = { string = stats.CHIP or "…" } })

  local total_bytes = tonumber(stats.MEM_TOTAL_BYTES) or 0
  local total_gb = total_bytes > 0 and total_bytes / 1073741824 or nil
  local used_gb = to_gb(stats.MEM_USED)
  if used_gb and total_gb then
    local pct = math.floor(used_gb / total_gb * 100 + 0.5)
    mem_gauge:set({
      gauge = { percentage = pct, color = cpu_color_for(pct) },
      label = pct .. "%",
    })
    mem_detail:set({
      icon = { string = fmt_size(used_gb) .. " of " .. fmt_size(total_gb) },
    })
  end

end

local function hide_popup()
  cpu_bracket:set({ popup = { drawing = false } })
end

-- Last GPU figures, so a freshly opened popup paints the title and memory
-- row at once instead of waiting for the next tick.
local last_gpu = nil        -- 0-100
local last_gpu_mb = nil     -- in-use memory, MB (absent on some drivers)
local gpu_shown = false

local function paint_gpu()
  if not last_gpu then return end
  gpu_title:set({
    label = { string = last_gpu .. "%", color = cpu_color_for(last_gpu) },
  })
  gpu_detail:set({
    drawing = last_gpu_mb ~= nil,
    icon = { string = last_gpu_mb and (fmt_size(last_gpu_mb / 1024) .. " in use") or "…" },
  })
end

local function show_gpu_section()
  if gpu_shown then return end
  gpu_shown = true
  gpu_sep:set({ drawing = true })
  gpu_title:set({ drawing = true })
  gpu_hist:set({ drawing = true })
end

local last_refresh = 0

local function refresh_popup()
  last_refresh = os.time()
  sbar.exec("sh '" .. stats_script:gsub("'", "'\\''") .. "' 2>/dev/null", function(out)
    update_popup_from_helper(out)
  end)
end

local function schedule_popup_update()
  if cpu_bracket:query().popup.drawing ~= "on" then return end
  refresh_popup()
  sbar.delay(3, schedule_popup_update)
end

local function toggle_popup()
  local should_draw = cpu_bracket:query().popup.drawing == "off"
  if should_draw then
    cpu_bracket:set({ popup = { drawing = true } })
    paint_gpu()
    refresh_popup()
    sbar.delay(3, schedule_popup_update)
  else
    hide_popup()
  end
end

-- ── Events ────────────────────────────────────────────────────────────────
cpu:subscribe("system_stats", function(env)  -- YBAR PORT: built-in provider
  local load = tonumber(env.CPU_USAGE) or 0
  cpu:push({ load / 100. })

  local color = cpu_color_for(load)

  cpu:set({ graph = { color = color } })

  -- GPU rides the same tick; the key is absent when the driver has no
  -- figure, and the section stays hidden with it.
  local gpu = tonumber(env.GPU_USAGE)
  if gpu then
    last_gpu = gpu
    last_gpu_mb = tonumber(env.GPU_MEMORY_USED_MB)
    show_gpu_section()
    gpu_hist:push({ gpu / 100. })
    gpu_hist:set({ graph = { color = cpu_color_for(gpu) } })
  end

  if cpu_bracket:query().popup.drawing == "on" then
    cpu_gauge:set({
      gauge = { percentage = load, color = color },
      label = load .. "%",
    })
    if gpu then paint_gpu() end
    -- Keep the panel fresh even when it was opened without a click
    -- (CLI toggle) and the scheduled loop never started.
    if os.time() - last_refresh >= 3 then refresh_popup() end
  end
end)

header:subscribe("mouse.clicked", function()
  sbar.exec("open -a 'Activity Monitor'")
  hide_popup()
end)


cpu:subscribe("mouse.clicked", toggle_popup)
cpu:subscribe("mouse.exited.global", hide_popup)

sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings
})
