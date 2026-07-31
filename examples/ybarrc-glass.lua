-- YBar Liquid Glass — a Tahoe-style floating-capsule bar.
-- Install:  cp examples/ybarrc-glass.lua ~/.config/ybar/ybarrc.lua
--
-- Every capsule is real glass: a blurred system-material backdrop
-- (blur_radius) under a Metal-rendered pill with an in-shader specular rim
-- and vertical sheen (background.glass). Nothing here is achievable in
-- sketchybar without per-item windows and private blur APIs.

local glass = {
  fill        = "0x30ffffff",  -- 19% white over the blur
  fill_hover  = "0x55ffffff",
  fill_active = "0x66ffffff",
  text        = "0xf2ffffff",
  text_dim    = "0x8affffff",
  accent      = "0xffffd60a",  -- battery low / warnings
  green       = "0xff30d158",
  blue        = "0xff0a84ff",
}

local CAPSULE_H = 30
local RADIUS = 99  -- clamps to height/2 = capsule

ybar.bar({
  height = 42,
  color = "0x00000000",   -- fully transparent: capsules float
  padding_left = 6,
  padding_right = 6,
})

ybar.default({
  icon = { color = glass.text, padding_left = 10, padding_right = 5,
           font = { size = 13 } },
  label = { color = glass.text, padding_left = 0, padding_right = 10,
            font = { size = 13 } },
  background = {
    drawing = true,
    color = glass.fill,
    corner_radius = RADIUS,
    height = CAPSULE_H,
    glass = true,
  },
  blur_radius = 30,
  padding_left = 4,
  padding_right = 4,
})

-- Hover glow shared by all interactive capsules.
local function hoverable(item, base_color)
  item:subscribe("mouse.entered", function()
    ybar.animate("tanh", 18, function()
      item:set({ background = { color = glass.fill_hover } })
    end)
  end)
  item:subscribe("mouse.exited", function()
    ybar.animate("tanh", 18, function()
      item:set({ background = { color = base_color or glass.fill } })
    end)
  end)
end

-- ── Workspaces: one glass capsule each ───────────────────────────────────
local app_icons_ok, app_icons = pcall(require, "helpers.app_icons")
if not app_icons_ok then app_icons = nil end

local workspaces = {}
ybar.add_event("aerospace_workspace_change")

ybar.exec("aerospace list-workspaces --all 2>/dev/null", function(output)
  for line in output:gmatch("[^\r\n]+") do
    local sid = line:match("^%s*(.-)%s*$")
    if sid ~= "" and not workspaces[sid] then
      local ws = ybar.add("item", "glass.space." .. sid, "left")
      ws:set({
        icon = sid,
        ["icon.font.size"] = 12,
        ["icon.padding_right"] = 8,
        label = { drawing = false },
        drawing = false,
        click_script = "aerospace workspace " .. sid,
      })
      hoverable(ws)
      workspaces[sid] = ws
    end
  end
  ybar.trigger("glass_refresh_spaces")
end)

ybar.add_event("glass_refresh_spaces")

local spaces_observer = ybar.add("item", "glass.spaces.observer", "left")
spaces_observer:set({ drawing = false })

local function refresh_spaces(focused)
  ybar.exec("aerospace list-workspaces --monitor all --empty no 2>/dev/null", function(nonempty)
    local visible = {}
    for line in nonempty:gmatch("[^\r\n]+") do
      visible[line:match("^%s*(.-)%s*$")] = true
    end
    if focused and focused ~= "" then visible[focused] = true end
    for sid, ws in pairs(workspaces) do
      local selected = (sid == focused)
      ws:set({
        drawing = visible[sid] and "on" or "off",
        background = { color = selected and glass.fill_active or glass.fill },
        ["icon.color"] = selected and glass.text or glass.text_dim,
      })
    end
  end)
end

local function query_focus_and_refresh()
  ybar.exec("aerospace list-workspaces --focused 2>/dev/null", function(out)
    refresh_spaces(out:gsub("%s+", ""))
  end)
end

spaces_observer:subscribe("aerospace_workspace_change", function(env)
  if env.FOCUSED_WORKSPACE and env.FOCUSED_WORKSPACE ~= "" then
    refresh_spaces(env.FOCUSED_WORKSPACE)
  else
    query_focus_and_refresh()
  end
end)
spaces_observer:subscribe("glass_refresh_spaces", query_focus_and_refresh)
spaces_observer:subscribe("front_app_switched", query_focus_and_refresh)

-- ── Front app ────────────────────────────────────────────────────────────
local front = ybar.add("item", "glass.front", "left")
front:set({
  icon = "sf:macwindow",
  ["icon.color"] = glass.blue,
  padding_left = 10,
})
front:subscribe("front_app_switched", function(env)
  front:set({ label = env.INFO })
end)

-- ── Center clock ─────────────────────────────────────────────────────────
local clock = ybar.add("item", "glass.clock", "center")
clock:set({
  icon = { drawing = false },
  label = os.date("%a %d %b  %H:%M"),
  ["label.padding_left"] = 12,
  ["label.padding_right"] = 12,
  ["label.font.size"] = 13,
  update_freq = 20,
})
clock:subscribe("routine", function()
  clock:set({ label = os.date("%a %d %b  %H:%M") })
end)
hoverable(clock)

-- ── Right cluster ────────────────────────────────────────────────────────
-- Wi-Fi
local wifi = ybar.add("item", "glass.wifi", "right")
wifi:set({ icon = "sf:wifi", ["icon.padding_right"] = 10, label = { drawing = false } })
wifi:subscribe("wifi_change", function(env)
  wifi:set({ icon = (env.INFO ~= "" and "sf:wifi" or "sf:wifi.slash") })
end)
hoverable(wifi)

-- Battery
local battery = ybar.add("item", "glass.battery", "right")
battery:set({ icon = "sf:battery.100percent", ["icon.color"] = glass.green })
battery:subscribe({ "battery_change", "power_source_change", "forced" }, function(env)
  local pct = tonumber(env.INFO)
  if not pct then return end
  local icon, color = "sf:battery.100percent", glass.green
  if pct <= 20 then icon, color = "sf:battery.25percent", glass.accent
  elseif pct <= 50 then icon = "sf:battery.50percent"
  elseif pct <= 75 then icon = "sf:battery.75percent" end
  battery:set({ icon = icon, ["icon.color"] = color, label = pct .. "%" })
end)
hoverable(battery)

-- Volume: glass capsule with an inline slider
local vol = ybar.add("slider", "glass.volume", "right", 70)
vol:set({
  icon = "sf:speaker.wave.2.fill",
  ["icon.padding_right"] = 8,
  label = { drawing = false },
  ["label.padding_right"] = 4,
  slider = {
    highlight_color = glass.text,
    background = { color = "0x33ffffff", height = 4, corner_radius = 2 },
    knob = { drawing = false },
  },
  padding_right = 6,
})
vol:subscribe("volume_change", function(env)
  vol:set({ slider = { percentage = env.INFO } })
end)
vol:subscribe("mouse.clicked", function(env)
  if env.PERCENTAGE then
    ybar.exec("osascript -e 'set volume output volume " .. env.PERCENTAGE .. "'")
  end
end)
hoverable(vol)

-- CPU graph in glass
local cpu = ybar.add("graph", "glass.cpu", "right", 46)
cpu:set({
  icon = "sf:cpu",
  ["icon.padding_right"] = 6,
  ["label.font.size"] = 10,
  ["label.color"] = glass.text_dim,
  graph = { color = glass.blue },
  background = { height = CAPSULE_H },
})
cpu:subscribe("system_stats", function(env)
  cpu:push({ (tonumber(env.CPU_FRACTION) or 0) })
  cpu:set({ label = env.CPU_USAGE .. "%" })
end)
hoverable(cpu)

-- Boot: populate everything once (update runs forced/routine handlers;
-- the triggers force provider re-queries so event-driven capsules fill in).
ybar.update()
ybar.trigger("battery_change")
ybar.trigger("volume_change")
ybar.trigger("wifi_change")
