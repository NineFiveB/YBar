local colors = require("colors")
local settings = require("settings")

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
  popup = { align = "center" },
})

require("helpers.hover").pill(cpu_bracket, cpu)

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
  padding_top = 4,
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
    padding_top = 4,
  })
end

local mem_card = add_card("Memory", "Free Up")
local cpu_card = add_card("CPU", "—°C")
local gpu_card = add_card("GPU", "—°C")
gpu_card:set({ drawing = false })

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
  padding_top = 8,
  padding_bottom = 6,
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

local function temp_label(raw)
  local n = tonumber(raw)
  if not n then return "—°C" end
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
  if stats.GPU_TEMP then
    gpu_card:set({ label = { string = temp_label(stats.GPU_TEMP) } })
  end

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
  cpu_card:set({
    icon = { string = string.format("CPU    Load: %d%%", load) },
  })
  local gpu = tonumber(env.GPU_USAGE)
  if gpu then
    if not gpu_shown then
      gpu_shown = true
      gpu_card:set({ drawing = true })
    end
    gpu_card:set({
      icon = { string = string.format("GPU    Load: %d%%", gpu) },
    })
  end
  if cpu_bracket:query().popup.drawing == "on" and os.time() - last_refresh >= 3 then
    refresh_popup()
  end
end)

mem_card:subscribe("mouse.clicked", function()
  sbar.exec("open -a 'Activity Monitor'")
  hide_popup()
end)
header:subscribe("mouse.clicked", function()
  sbar.exec("open -a 'Activity Monitor'")
  hide_popup()
end)

cpu:subscribe("mouse.clicked", toggle_popup)
cpu:subscribe("mouse.exited.global", hide_popup)

sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings,
})
