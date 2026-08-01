local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- YBAR PORT: the cpu_load event-provider binary is replaced by YBar's
-- built-in system_stats event (in-process host_statistics sampling).
-- The popup is an Apple-style sectioned panel (no graphs): every left
-- label sits on one of two indents, every value ends on the same right
-- edge, SF Pro throughout, units normalized in Lua.

local stats_script = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/system_stats_rich.sh"

local popup_width = 260
local inset = 12          -- shared left/right content inset
local detail_indent = 24  -- detail rows indent under their section

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
  popup = { align = "center", height = 30 }
})

-- ── Popup: Apple-style sectioned panel ────────────────────────────────────
local popup_pos = "popup." .. cpu_bracket.name

sbar.add("item", "widgets.cpu.popup.header", {
  position = popup_pos,
  width = popup_width,
  align = "center",
  icon = { string = icons.cpu, font = { style = settings.font.style_map["Bold"], size = 14.0 } },
  label = { string = "System Monitor", font = { size = 15, style = settings.font.style_map["Bold"] } },
  background = { height = 2, color = colors.grey, y_offset = -15 },
  padding_bottom = 4,
})

-- Section row: semibold title, prominent value, shared columns.
local function add_section(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      string = title,
      align = "left",
      width = popup_width / 2,
      color = colors.white,
      font = { size = 13, style = settings.font.style_map["Semibold"] },
      padding_left = inset,
    },
    label = {
      string = "…",
      align = "right",
      width = popup_width / 2,
      color = colors.white,
      font = { size = 13, style = settings.font.style_map["Semibold"] },
      padding_right = inset,
    },
    padding_top = 4,
  })
end

-- Detail row: secondary color, indented label, value on the shared right edge.
local function add_detail(title)
  return sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = {
      string = title,
      align = "left",
      width = popup_width / 2,
      color = colors.grey,
      font = { size = 12.0 },
      padding_left = detail_indent,
    },
    label = {
      string = "…",
      align = "right",
      width = popup_width / 2,
      color = colors.grey,
      font = { size = 12.0, style = settings.font.style_map["Semibold"] },
      padding_right = inset,
    },
  })
end

local function add_separator()
  sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = { drawing = false },
    label = { drawing = false },
    background = {
      height = 2,
      color = colors.with_alpha(colors.grey, 0.3),
    },
  })
end

local cpu_section = add_section("CPU")
local cpu_user    = add_detail("User")
local cpu_system  = add_detail("System")

-- Load as a line: knobless slider in its own middle column, value in the
-- shared right column.
local cpu_load = sbar.add("slider", 60, {
  position = popup_pos,
  width = popup_width,
  slider = {
    highlight_color = colors.blue,
    percentage = 0,
    background = {
      height = 4,
      corner_radius = 2,
      color = colors.with_alpha(colors.grey, 0.3),
    },
    knob = { drawing = false },
  },
  icon = {
    string = "Load",
    align = "left",
    width = popup_width / 2,
    color = colors.grey,
    font = { size = 12.0 },
    padding_left = detail_indent,
  },
  label = {
    string = "…",
    align = "right",
    width = popup_width / 2 - 60,
    color = colors.grey,
    font = { size = 12.0, style = settings.font.style_map["Semibold"] },
    padding_right = inset,
  },
})

local cpu_top = add_detail("Top Process")
add_separator()
local mem_section  = add_section("Memory")
local mem_pressure = add_detail("Pressure")
local mem_swap     = add_detail("Swap")
add_separator()
local gpu_section  = add_section("GPU")
add_separator()
local disk_section = add_section("Disk")
local disk_free    = add_detail("Free")
add_separator()
local up_section   = add_section("Uptime")

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

-- "23G" / "646.38M" / "1995G" (df/top SI suffixes) -> GB.
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

local function format_uptime(boot_sec)
  local diff = os.time() - boot_sec
  if diff <= 0 then return "—" end
  local days = math.floor(diff / 86400)
  local hours = math.floor((diff % 86400) / 3600)
  local mins = math.floor((diff % 3600) / 60)
  if days > 0 then return days .. "d " .. hours .. "h" end
  if hours > 0 then return hours .. "h " .. mins .. "m" end
  return mins .. "m"
end

local function update_popup_from_helper(out)
  local stats = parse_system_stats(out)

  local user = tonumber(stats.CPU_USER)
  local sys = tonumber(stats.CPU_SYS)
  cpu_user:set({ label = user and string.format("%.0f%%", user) or "—" })
  cpu_system:set({ label = sys and string.format("%.0f%%", sys) or "—" })

  local load1 = tonumber(stats.LOAD1)
  local ncpu = tonumber(stats.NCPU) or 1
  local load_pct = load1 and math.min(math.floor(load1 / ncpu * 100 + 0.5), 100) or 0
  cpu_load:set({
    slider = {
      percentage = load_pct,
      highlight_color = cpu_color_for(load_pct),
    },
    label = load1 and string.format("%.1f", load1) or "—",
  })

  local top_cpu = tonumber(stats.TOP_CPU)
  cpu_top:set({
    label = (stats.TOP_NAME and top_cpu)
      and string.format("%s  %.0f%%", stats.TOP_NAME, top_cpu) or "—",
  })

  local total_bytes = tonumber(stats.MEM_TOTAL_BYTES) or 0
  local total_gb = total_bytes > 0 and total_bytes / 1073741824 or nil
  local used_gb = to_gb(stats.MEM_USED)
  mem_section:set({
    label = (used_gb and total_gb)
      and (fmt_size(used_gb) .. " of " .. fmt_size(total_gb)) or "—",
  })
  local pressure = stats.MEM_PRESSURE or "—"
  mem_pressure:set({
    label = {
      string = pressure,
      color = pressure == "Normal" and colors.grey
        or (pressure == "Warning" and colors.yellow or colors.red),
    },
  })
  mem_swap:set({ label = fmt_size(to_gb(stats.SWAP_USED)) })

  local gpu = tonumber(stats.GPU)
  gpu_section:set({
    label = {
      string = gpu and (gpu .. "%") or "N/A",
      color = gpu and cpu_color_for(gpu) or colors.grey,
    },
  })

  disk_section:set({
    label = fmt_size(to_gb(stats.DISK_USED)) .. " of " .. fmt_size(to_gb(stats.DISK_SIZE)),
  })
  disk_free:set({ label = fmt_size(to_gb(stats.DISK_AVAIL)) })

  local boot = tonumber(stats.BOOT_SEC)
  up_section:set({ label = boot and format_uptime(boot) or "—" })
end

local function hide_popup()
  cpu_bracket:set({ popup = { drawing = false } })
end

local function refresh_popup()
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
    cpu_section:set({
      label = { string = load .. "%", color = color },
    })
  end
end)

cpu:subscribe("mouse.clicked", toggle_popup)
cpu:subscribe("mouse.exited.global", hide_popup)

sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings
})
