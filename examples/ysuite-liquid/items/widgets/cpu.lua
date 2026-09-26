local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")

-- Liquid Glass system monitor: sparkline pill (no glyph) and a card popup
-- matching the webpage — Memory / CPU / GPU rows plus the Disk footer.

local stats_script = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/system_stats_rich.sh"

local popup_width = 320
local inset = 12
local card = colors.selection
local sub = colors.with_alpha(colors.white, 0.55)

local cpu = sbar.add("graph", "widgets.cpu", 42, {
  position = "right",
  -- No fill: the default 20% wash reads as a baseline under the stroke.
  graph = { color = colors.white, fill_color = colors.transparent, line_width = 1.5 },
  background = {
    height = 12,
    color = { alpha = 0 },
    border_color = { alpha = 0 },
    drawing = true,
  },
  icon = { drawing = false },
  label = { drawing = false },
  padding_left = 10,
  padding_right = 10,
})

local cpu_bracket = sbar.add("bracket", "widgets.cpu.bracket", { cpu.name }, {
  padding_left = 8,
  padding_right = 8,
  background = { color = colors.bg1 },
  -- horizontal + wrap_width so the CPU/GPU/RAM tabs share one line. Every
  -- other item in this popup is popup_width wide (the cards are
  -- popup_width - 8 inside 4pt padding), so they each still take a line.
  popup = { align = "center", horizontal = true, wrap_width = popup_width },
})

hover.pill(cpu_bracket, cpu)

local popup_pos = "popup." .. cpu_bracket.name

local header = sbar.add("item", "widgets.cpu.popup.header", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "System Monitor",
    align = "left",
    font = { size = 14, style = settings.font.style_map["Regular"] },
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

-- The aside is a short trailing word ("Free Up", a temperature). The title
-- takes the rest so "Available: 10.3 GB" is not clipped at the halfway mark.
local aside_width = 84
local title_width = popup_width - 8 - aside_width

local function add_card(title, aside)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width - 8,
    background = {
      height = 52,
      corner_radius = 16,
      color = card,
      drawing = true,
      glass = false,
      sheen = false,
    },
    icon = {
      string = title,
      align = "left",
      font = { size = 13, style = settings.font.style_map["Regular"] },
      color = colors.white,
      width = title_width,
      padding_left = 14,
    },
    label = {
      string = aside,
      align = "right",
      font = { size = 13, style = settings.font.style_map["Regular"] },
      color = colors.white,
      width = aside_width,
      padding_right = 14,
    },
    padding_left = 4,
    padding_right = 4,
  })
end

local mem_card = add_card("Memory", "Free Up")
-- The temperature asides start empty rather than at a "—°C" placeholder.
-- system_stats_rich.sh emits CPU_TEMP only when a temperature tool it can
-- find answers (none ships with the theme), and it has no GPU temperature
-- at all: its GPU key is the same IOAccelerator utilisation the engine's
-- system_stats event already puts in the card title below, so the GPU aside
-- stays empty instead of repeating the load.
local cpu_card = add_card("CPU", "")
local gpu_card = add_card("GPU", "")
gpu_card:set({ drawing = false })

-- Every card opens Activity Monitor, and until now none of them looked like
-- it would: a card is the only clickable surface in this popup and it rested
-- at the same tone whether the pointer was on it or not.
local card_hover = colors.with_alpha(colors.white, 0.11)
for _, item in ipairs({ mem_card, cpu_card, gpu_card }) do
  hover.attachColor(item, { item }, card, card_hover)
end

-- ── Usage history ──────────────────────────────────────────────────────────
-- The pill's sparkline is 42 samples with no scale and no readout: it says
-- "busy" and nothing else. The popup plots the same stream as a scrubbable
-- bar chart behind a CPU / GPU / RAM switch, the way the battery popup plots
-- its charge behind 24 Hours / 10 Days. Bars, not a line, because the engine
-- only hit-tests bars graphs for graph.hovered.
--
-- All three series come off the one system_stats event the pill already
-- subscribes to (CPU_USAGE, GPU_USAGE, MEMORY_USAGE), so switching tabs reads
-- history that was already being kept rather than starting a new recording.
local history_buckets = 64
local plot_width = popup_width - 2 * inset - 36   -- room for the y-axis strip
local inner = popup_width - 2 * inset
local tab_track = colors.with_alpha(0xff000000, 0.38)
local tab_active = 0xff0a84ff

local series = {
  cpu = { title = "CPU Load", values = {}, times = {} },
  gpu = { title = "GPU Load", values = {}, times = {} },
  ram = { title = "Memory Used", values = {}, times = {} },
}
for _, entry in pairs(series) do
  for i = 1, history_buckets do
    entry.values[i] = false
    entry.times[i] = false
  end
end
local shown_series = "cpu"

-- Three tabs when the machine reports a GPU, two when it does not: the GPU
-- card hides itself on the same signal, and a tab onto a chart that can never
-- fill is worse than no tab.
local tab_w3 = (inner - 8) / 3
local tab_w2 = (inner - 4) / 2

local function add_tab(key, text, pad_left, pad_right)
  local tab = sbar.add("item", "widgets.cpu.tab." .. key, {
    position = popup_pos,
    width = tab_w3,
    align = "center",
    icon = {
      string = text,
      font = { size = 12, style = settings.font.style_map["Regular"] },
      color = colors.white,
    },
    label = { drawing = false },
    background = {
      height = 26,
      corner_radius = 7,
      color = tab_track,
      drawing = true,
      glass = false,
      sheen = false,
    },
    padding_left = pad_left or 0,
    padding_right = pad_right or 0,
  })
  return tab
end

local tabs = {
  cpu = add_tab("cpu", "CPU", inset, 0),
  gpu = add_tab("gpu", "GPU", 0, 0),
  ram = add_tab("ram", "RAM", 0, inset),
}

local chart_title = sbar.add("item", "widgets.cpu.chart_title", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = series.cpu.title,
    align = "left",
    font = { size = 13, style = settings.font.style_map["Regular"] },
    color = colors.white,
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

-- A single space at rest so the chart does not jump up when the readout
-- appears under the pointer.
local chart_detail = sbar.add("item", "widgets.cpu.chart_detail", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = " ",
    align = "left",
    font = { size = 12, style = settings.font.style_map["Regular"] },
    color = colors.with_alpha(colors.white, 0.85),
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

local function add_history(key, drawing)
  return sbar.add("graph", "widgets.cpu.history." .. key, history_buckets, {
    position = popup_pos,
    drawing = drawing,
    graph = {
      color = colors.with_alpha(colors.white, 0.7),
      style = "bars",
      plot_width = plot_width,
      tick = "off",
    },
    background = {
      height = 72,
      color = { alpha = 0 },
      border_color = { alpha = 0 },
      drawing = true,
    },
    icon = { drawing = false },
    label = { drawing = false },
    padding_left = inset,
    padding_right = 0,
  })
end

series.cpu.graph = add_history("cpu", true)
series.gpu.graph = add_history("gpu", false)
series.ram.graph = add_history("ram", false)

local function ago(seconds)
  if seconds < 10 then return "now" end
  if seconds < 90 then return string.format("%ds ago", seconds) end
  return string.format("%dm ago", math.floor(seconds / 60 + 0.5))
end

local function record(key, value)
  local entry = series[key]
  if not entry or not value then return end
  table.move(entry.values, 2, history_buckets, 1)
  table.move(entry.times, 2, history_buckets, 1)
  entry.values[history_buckets] = value
  entry.times[history_buckets] = os.time()
  entry.graph:push({ math.max(0, math.min(1, value / 100)) })
end

local function paint_tabs()
  for key, tab in pairs(tabs) do
    tab:set({
      background = { color = key == shown_series and tab_active or tab_track },
      icon = { color = key == shown_series and colors.white
        or colors.with_alpha(colors.white, 0.88) },
    })
  end
end

local function set_series(key)
  if shown_series == key or not series[key] then return end
  shown_series = key
  chart_detail:set({ icon = { string = " " } })
  chart_title:set({ icon = { string = series[key].title } })
  for name, entry in pairs(series) do
    entry.graph:set({ drawing = name == key })
  end
  paint_tabs()
end

for key, tab in pairs(tabs) do
  tab:subscribe("mouse.clicked", function() set_series(key) end)
  -- The track tone is the resting state, so the hover lift has to come back
  -- to whichever tone the tab is currently wearing.
  tab:subscribe("mouse.entered", function()
    if shown_series == key then return end
    hover.fade(tab, colors.with_alpha(colors.white, 0.16), hover.ENTER_FRAMES)
  end)
  tab:subscribe("mouse.exited", function()
    if shown_series == key then return end
    hover.fade(tab, tab_track, hover.EXIT_FRAMES)
  end)
end

-- One handler for all three: a graph only reports hovers while it is drawing,
-- so the readout always belongs to the series on screen.
local function on_scrub(env)
  local index = tonumber(env.INFO)
  local entry = series[shown_series]
  local value = index and entry and entry.values[index + 1]
  if not value then
    chart_detail:set({ icon = { string = " " } })
    return
  end
  local when = entry.times[index + 1]
  chart_detail:set({
    icon = {
      string = string.format("%s  ·  %d%%",
        ago(os.time() - (when or os.time())), value),
    },
  })
end

for _, entry in pairs(series) do
  entry.graph:subscribe("graph.hovered", on_scrub)
end

-- Until a GPU reading lands, CPU and RAM split the strip between them.
local function fit_tabs(with_gpu)
  if with_gpu then
    tabs.cpu:set({ width = tab_w3 })
    tabs.gpu:set({ drawing = true, width = tab_w3 })
    tabs.ram:set({ width = tab_w3 })
  else
    tabs.cpu:set({ width = tab_w2 })
    tabs.gpu:set({ drawing = false, width = 0 })
    tabs.ram:set({ width = tab_w2 })
  end
end
fit_tabs(false)
paint_tabs()

local footer = sbar.add("item", "widgets.cpu.footer", {
  position = popup_pos,
  width = popup_width,
  align = "center",
  icon = {
    string = "Disk — · ↓ — · ↑ —",
    color = colors.with_alpha(colors.white, 0.62),
    font = { size = 11 },
  },
  label = { drawing = false },
})

local function parse_stats(out)
  local stats = {}
  for line in string.gmatch(out or "", "[^\r\n]+") do
    local k, v = line:match("^([%w_]+)=(.*)$")
    if k and v then stats[k] = v end
  end
  return stats
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

local function fmt_rate(bytes_per_sec)
  if not bytes_per_sec or bytes_per_sec < 0 then return "—" end
  if bytes_per_sec < 1024 * 1024 then
    return string.format("%.1f KB/s", bytes_per_sec / 1024)
  end
  return string.format("%.1f MB/s", bytes_per_sec / (1024 * 1024))
end

-- Empty when the helper had no reading. A zero counts as none: the one
-- tool the helper knows reports 0.0 °C on Apple Silicon.
local function temp_label(raw)
  local n = tonumber(raw)
  if not n or n <= 0 then return "" end
  return string.format("%d°C", n)
end

local last_net_in, last_net_out, last_net_t = nil, nil, nil

local function update_from_helper(out)
  local stats = parse_stats(out)
  local total = tonumber(stats.MEM_TOTAL_BYTES) or 0
  local total_gb = total > 0 and total / 1073741824 or nil
  local free_pct = tonumber(stats.MEM_FREE_PCT)
  local avail = (free_pct and total_gb) and (total_gb * free_pct / 100) or nil
  if not avail then
    local used = to_gb(stats.MEM_USED)
    avail = (used and total_gb) and math.max(total_gb - used, 0) or nil
  end
  mem_card:set({
    icon = {
      string = avail and string.format("Memory    Available: %.1f GB", math.max(avail, 0))
        or "Memory",
    },
  })
  cpu_card:set({ label = { string = temp_label(stats.CPU_TEMP) } })

  local disk_pct = (stats.DISK_PCT or ""):gsub("%%", "")
  local net_in = tonumber(stats.NET_IN)
  local net_out = tonumber(stats.NET_OUT)
  local now = os.time()
  local down, up = "—", "—"
  if net_in and net_out and last_net_in and last_net_out and last_net_t and now > last_net_t then
    local dt = now - last_net_t
    down = fmt_rate((net_in - last_net_in) / dt)
    up = fmt_rate((net_out - last_net_out) / dt)
  end
  if net_in and net_out then
    last_net_in, last_net_out, last_net_t = net_in, net_out, now
  end
  local disk_label = disk_pct ~= "" and (disk_pct .. "%") or "—"
  footer:set({
    icon = { string = "Disk " .. disk_label .. " · ↓ " .. down .. " · ↑ " .. up },
  })
end

local last_refresh = 0
local function refresh_popup()
  last_refresh = os.time()
  sbar.exec("sh '" .. stats_script:gsub("'", "'\\''") .. "' 2>/dev/null", update_from_helper)
end

local function hide_popup()
  cpu_bracket:set({ popup = { drawing = false } })
end

local function schedule()
  if cpu_bracket:query().popup.drawing ~= "on" then return end
  refresh_popup()
  sbar.delay(3, schedule)
end

local function toggle_popup()
  local open = cpu_bracket:query().popup.drawing == "off"
  if open then
    cpu_bracket:set({ popup = { drawing = true } })
    refresh_popup()
    sbar.delay(3, schedule)
  else
    hide_popup()
  end
end

local gpu_shown = false

-- Samples are 0 at the bottom of the plot and 1 at the top. Keep the
-- stroke in a band around the middle, and nudge a high spike down so it
-- does not ride the top of the capsule.
local function waveform(load)
  local s = math.max(0, math.min(1, (tonumber(load) or 0) / 100))
  local y = 0.5 + (s - 0.5) * 0.42
  if s > 0.7 then
    y = y - 0.08 * ((s - 0.7) / 0.3)
  end
  return math.max(0.22, math.min(0.74, y))
end

cpu:subscribe("system_stats", function(env)
  local load = tonumber(env.CPU_USAGE) or 0
  cpu:push({ waveform(load) })
  record("cpu", load)
  record("ram", tonumber(env.MEMORY_USAGE))
  cpu_card:set({
    icon = { string = string.format("CPU    Load: %d%%", load) },
  })
  local gpu = tonumber(env.GPU_USAGE)
  if gpu then
    record("gpu", gpu)
    if not gpu_shown then
      gpu_shown = true
      gpu_card:set({ drawing = true })
      -- The GPU tab appears on the same signal as the GPU card, and only
      -- once: a machine that never reports one keeps a two-way switch
      -- rather than a tab onto a chart that can never fill.
      fit_tabs(true)
    end
    gpu_card:set({
      icon = { string = string.format("GPU    Load: %d%%", gpu) },
    })
  end
  if cpu_bracket:query().popup.drawing == "on" and os.time() - last_refresh >= 3 then
    refresh_popup()
  end
end)

local function open_activity_monitor()
  sbar.exec("open -a 'Activity Monitor'")
  hide_popup()
end

for _, item in ipairs({ header, mem_card, cpu_card, gpu_card }) do
  item:subscribe("mouse.clicked", open_activity_monitor)
end
hover.row(header, { height = 22, radius = 6, flat = true })

cpu:subscribe("mouse.clicked", toggle_popup)
cpu:subscribe("mouse.exited.global", hide_popup)

sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings,
})
