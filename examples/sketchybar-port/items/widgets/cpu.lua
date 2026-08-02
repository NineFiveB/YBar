local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: system monitor popup in the Stats-app dashboard style:
-- arc gauges (YBar's gauge component) for CPU and memory, disk with a
-- percentage + line, and live network throughput — each tile a stack of
-- centered rows. Data from helpers/system_stats_rich.sh; network rates
-- from successive byte-counter deltas.

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
  icon = {
    align = "left",
    string = "System Monitor",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = icons.gear,
    color = colors.grey,
    font = { size = 13 },
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
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

local cpu_gauge   = add_gauge()
add_center(icons.cpu .. "  CPU LOAD")
local cpu_chip    = add_center("…", { color = colors.grey, size = 11, style = "Regular" })
add_separator()
local mem_gauge   = add_gauge()
add_center("MEMORY")
local mem_detail  = add_center("…", { color = colors.grey, size = 11, style = "Regular" })
add_separator()
local disk_pct    = add_center("…", { size = 17 })
local disk_slider = sbar.add("slider", 170, {
  position = popup_pos,
  width = popup_width,
  align = "center",
  slider = {
    highlight_color = colors.blue,
    percentage = 0,
    background = {
      height = 5,
      corner_radius = 2,
      color = colors.with_alpha(colors.grey, 0.25),
    },
    knob = { drawing = false },
  },
  icon = { drawing = false },
  label = { drawing = false },
})
local disk_title  = add_center("DISK")
local disk_detail = add_center("…", { color = colors.grey, size = 11, style = "Regular" })
add_separator()
local net_up      = add_center("↑  …", { size = 14 })
local net_down    = add_center("↓  …", { size = 14 })
add_center(icons.wifi.connected .. "  Wi-Fi", { color = colors.grey, size = 11, style = "Regular" })

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

local function fmt_rate(bytes_per_s)
  if not bytes_per_s or bytes_per_s < 0 then return "…" end
  if bytes_per_s >= 1048576 then
    return string.format("%.1f MB/s", bytes_per_s / 1048576)
  end
  if bytes_per_s >= 1024 then
    return string.format("%.1f KB/s", bytes_per_s / 1024)
  end
  return string.format("%.0f B/s", bytes_per_s)
end

local net_prev = nil   -- { inb, outb, t }

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

  local disk_used_pct = tonumber((stats.DISK_PCT or ""):match("(%d+)"))
  if disk_used_pct then
    disk_pct:set({ icon = { string = disk_used_pct .. "%" } })
    disk_slider:set({
      slider = {
        percentage = disk_used_pct,
        highlight_color = cpu_color_for(disk_used_pct),
      },
    })
  end
  disk_title:set({ icon = { string = stats.DISK_NAME or "DISK" } })
  disk_detail:set({
    icon = {
      string = fmt_size(to_gb(stats.DISK_USED)) .. " of " .. fmt_size(to_gb(stats.DISK_SIZE)),
    },
  })

  local inb, outb = tonumber(stats.NET_IN), tonumber(stats.NET_OUT)
  local now = os.time()
  if inb and outb then
    if net_prev and now > net_prev.t then
      local dt = now - net_prev.t
      net_down:set({ icon = { string = "↓  " .. fmt_rate((inb - net_prev.inb) / dt) } })
      net_up:set({ icon = { string = "↑  " .. fmt_rate((outb - net_prev.outb) / dt) } })
    end
    net_prev = { inb = inb, outb = outb, t = now }
  end
end

local function hide_popup()
  cpu_bracket:set({ popup = { drawing = false } })
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

  cpu:set({
    graph = { color = color },
    label = "cpu " .. load .. "%",
  })

  if cpu_bracket:query().popup.drawing == "on" then
    cpu_gauge:set({
      gauge = { percentage = load, color = color },
      label = load .. "%",
    })
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
