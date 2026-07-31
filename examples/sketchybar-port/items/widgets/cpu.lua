local icons = require("icons")
local colors = require("colors")
local settings = require("settings")

-- Config dir: sketchybar sets CONFIG_DIR when item scripts run; at load time use fallback
local config_dir = SKETCHYBAR_CONFIG  -- YBAR PORT: helpers live in the original tree
local cpu_load_bin = config_dir .. "/helpers/event_providers/cpu_load/bin/cpu_load"
local system_stats_script = config_dir .. "/helpers/system_stats.sh"

-- YBAR PORT: the cpu_load event-provider binary is replaced by YBar's
-- built-in system_stats event (in-process host_statistics sampling).

local popup_width = 250
local slider_width = 135

local function make_slider(label_text, highlight_color, popup_pos)
  return sbar.add("slider", slider_width, {
    position = popup_pos,
    width = popup_width,
    slider = {
      highlight_color = highlight_color,
      background = {
        height = 6,
        corner_radius = 3,
        color = colors.with_alpha(colors.bg2, 0.8),
      },
      knob = { drawing = false },
      percentage = 0,
    },
    icon = {
      string = label_text,
      color = colors.grey,
      font = {
        family = settings.font.numbers,
        style = settings.font.style_map["Bold"],
        size = 11.0,
      },
      width = 42,
      align = "left",
      padding_left = 8,
    },
    label = {
      string = "??%",
      font = {
        family = settings.font.numbers,
        style = settings.font.style_map["Bold"],
        size = 12.0,
      },
      width = 40,
      align = "right",
      padding_right = 8,
    },
    padding_top = 5,
    padding_bottom = 5,
  })
end

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

-- ── Popup ─────────────────────────────────────────────────────────────────
local popup_pos = "popup." .. cpu_bracket.name

sbar.add("item", "widgets.cpu.popup.header", {
  position = popup_pos,
  width = popup_width,
  align = "center",
  icon = { string = icons.cpu, font = { style = settings.font.style_map["Bold"], size = 14.0 } },
  label = { string = "Usage", font = { size = 15, style = settings.font.style_map["Bold"] } },
  background = { height = 2, color = colors.grey, y_offset = -15 },
  padding_bottom = 4,
})

local cpu_slider  = make_slider("CPU",  colors.blue,    popup_pos)
local ram_slider  = make_slider("RAM",  colors.green,   popup_pos)
local gpu_slider  = make_slider("GPU",  colors.magenta, popup_pos)

sbar.add("item", "widgets.cpu.popup.separator", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = {
    string = "─────────────────────────────",
    color = colors.with_alpha(colors.grey, 0.5),
    font = { size = 8.0 },
    align = "center",
  },
  padding_top = 2,
  padding_bottom = 2,
})

local disk_slider = make_slider("Disk", colors.yellow, popup_pos)

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

local function update_popup_from_helper(out)
  local stats = parse_system_stats(out)
  local ram = tonumber(stats.RAM) or 0
  local gpu = tonumber(stats.GPU) or 0
  local disk_free = stats.DISK_FREE or "?"
  local disk_total = stats.DISK_TOTAL or "?"

  ram_slider:set({ slider = { percentage = ram }, label = ram .. "%" })
  gpu_slider:set({ slider = { percentage = gpu }, label = (gpu > 0 and gpu .. "%" or "N/A") })

  local disk_free_n = tonumber(disk_free) or 0
  local disk_total_n = tonumber(disk_total) or 1
  local disk_used_pct = math.floor((disk_total_n - disk_free_n) / disk_total_n * 100)
  disk_slider:set({ slider = { percentage = disk_used_pct }, label = disk_used_pct .. "%" })
end

local function hide_popup()
  cpu_bracket:set({ popup = { drawing = false } })
end

local function schedule_popup_update()
  local drawing = cpu_bracket:query().popup.drawing == "on"
  if not drawing then return end
  sbar.exec("'" .. system_stats_script:gsub("'", "'\\''") .. "' 2>/dev/null", function(out)
    update_popup_from_helper(out)
  end)
  sbar.delay(2, schedule_popup_update)
end

local function toggle_popup()
  local should_draw = cpu_bracket:query().popup.drawing == "off"
  if should_draw then
    cpu_bracket:set({ popup = { drawing = true } })
    sbar.exec("'" .. system_stats_script:gsub("'", "'\\''") .. "' 2>/dev/null", function(out)
      update_popup_from_helper(out)
    end)
    sbar.delay(2, schedule_popup_update)
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
    cpu_slider:set({
      slider = { highlight_color = color, percentage = load },
      label = load .. "%",
    })
  end
end)

cpu:subscribe("mouse.clicked", toggle_popup)
cpu:subscribe("mouse.exited.global", hide_popup)

sbar.add("item", "widgets.cpu.padding", {
  position = "right",
  width = settings.group_paddings
})
