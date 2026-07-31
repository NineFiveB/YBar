-- YBar Liquid Glass (dark) — the sketchybar-setup layout in Tahoe glass.
-- Same elements, sizes, and placement as the sketchybar config; every pill is
-- dark glass (blurred backdrop + in-shader specular rim) with 20pt corners
-- (clamped to capsule on short pills, as macOS does).
-- Install:  cp examples/ybarrc-glass.lua ~/.config/ybar/ybarrc.lua
--           (plus helpers/app_icons.lua next to it for workspace app icons)

local glass = {
  fill        = "0x21262b36",  -- barely-there tint: the blur IS the material
  fill_hover  = "0x4d32384a",
  fill_active = "0x593a4154",
  text        = "0xffe2e2e3",  -- sonokai white
  dim         = "0xff7f8490",  -- sonokai grey
  red         = "0xfffc5d7c",
  green       = "0xff9ed072",
  blue        = "0xff76cce0",
  yellow      = "0xffe7c664",
}

local RADIUS = 20         -- macOS 26 corner radius
local ITEM_H = 28         -- sketchybar default background height
local paddings = 3        -- sketchybar settings.paddings

-- App icon map for workspace labels (sketchybar-app-font glyphs).
local ok, app_icons = pcall(require, "helpers.app_icons")
if not ok then ok, app_icons = pcall(require, "sketchybar-port.helpers.app_icons") end
if not ok then app_icons = nil end

ybar.bar({
  height = 40,
  color = "0x00000000",
  padding_left = 2,
  padding_right = 2,
})

ybar.default({
  updates = "when_shown",
  icon = { color = glass.text, padding_left = paddings, padding_right = paddings,
           font = { family = "SF Pro", style = "Bold", size = 14 } },
  label = { color = glass.text, padding_left = paddings, padding_right = paddings,
            font = { family = "SF Pro", style = "Semibold", size = 13 } },
  background = {
    drawing = true,
    color = glass.fill,
    corner_radius = RADIUS,
    height = ITEM_H,
    glass = true,
  },
  blur_radius = 30,
  padding_left = 5,
  padding_right = 5,
})

local function hoverable(item, base)
  item:subscribe("mouse.entered", function()
    ybar.animate("tanh", 18, function()
      item:set({ background = { color = glass.fill_hover } })
    end)
  end)
  item:subscribe("mouse.exited", function()
    ybar.animate("tanh", 18, function()
      item:set({ background = { color = base or glass.fill } })
    end)
  end)
end

-- ══ LEFT: workspaces ⇄ app menus (sketchybar swap, front_app stays visible) ══

ybar.add_event("aerospace_workspace_change")
ybar.add_event("glass_refresh_spaces")

local workspaces = {}

local function workspace_icons(sid, ws)
  ybar.exec("aerospace list-windows --workspace " .. sid ..
            " --format '%{app-name}' 2>/dev/null", function(windows)
    local line, seen = "", {}
    for raw in windows:gmatch("[^\r\n]+") do
      local app = raw:match("^%s*(.-)%s*$")
      if app ~= "" and not seen[app] then
        seen[app] = true
        local icon = app_icons and (app_icons[app] or app_icons["Default"]) or "•"
        line = line .. icon .. " "
      end
    end
    if line == "" then
      ws:set({ label = { drawing = false } })
    else
      ws:set({ label = { drawing = true, string = line } })
    end
  end)
end

ybar.exec("aerospace list-workspaces --all 2>/dev/null", function(output)
  for raw in output:gmatch("[^\r\n]+") do
    local sid = raw:match("^%s*(.-)%s*$")
    if sid ~= "" and not workspaces[sid] then
      local ws = ybar.add("item", "glass.space." .. sid, "left")
      ws:set({
        icon = sid,
        ["icon.font"] = "SF Mono:Bold:12.0",
        ["icon.padding_left"] = 8,
        ["icon.padding_right"] = 4,
        label = {
          drawing = false,
          padding_left = 2,
          padding_right = 8,
          color = glass.dim,
          font = "sketchybar-app-font:Regular:16.0",
          y_offset = -1,
        },
        drawing = false,
        click_script = "aerospace workspace " .. sid,
      })
      hoverable(ws)
      workspaces[sid] = ws
    end
  end
  ybar.trigger("glass_refresh_spaces")
end)

local observer = ybar.add("item", "glass.observer", "left")
observer:set({ drawing = false, updates = true })

local menus_visible = false

local function refresh_spaces(focused)
  if menus_visible then return end
  ybar.exec("aerospace list-workspaces --monitor all --empty no 2>/dev/null", function(nonempty)
    local visible = {}
    for raw in nonempty:gmatch("[^\r\n]+") do
      visible[raw:match("^%s*(.-)%s*$")] = true
    end
    if focused and focused ~= "" then visible[focused] = true end
    for sid, ws in pairs(workspaces) do
      local selected = (sid == focused)
      ws:set({
        drawing = visible[sid] and "on" or "off",
        background = { color = selected and glass.fill_active or glass.fill },
        ["icon.color"] = selected and glass.red or glass.text,
        ["label.color"] = selected and glass.text or glass.dim,
      })
      if visible[sid] then workspace_icons(sid, ws) end
    end
  end)
end

local function query_focus_and_refresh()
  ybar.exec("aerospace list-workspaces --focused 2>/dev/null", function(out)
    refresh_spaces(out:gsub("%s+", ""))
  end)
end

observer:subscribe("aerospace_workspace_change", function(env)
  if env.FOCUSED_WORKSPACE and env.FOCUSED_WORKSPACE ~= "" then
    refresh_spaces(env.FOCUSED_WORKSPACE)
  else
    query_focus_and_refresh()
  end
end)
observer:subscribe("glass_refresh_spaces", query_focus_and_refresh)

-- ── Front app: always visible, click toggles workspaces ⇄ app menus ──────
local front = ybar.add("item", "glass.front", "left")
front:set({
  icon = { drawing = false },
  ["label.font"] = "SF Pro:Black:12.0",
  updates = true,
})
front:subscribe("front_app_switched", function(env)
  front:set({ label = env.INFO })
  if menus_visible then ybar.trigger("glass_update_menus") end
  query_focus_and_refresh()
end)
hoverable(front)

-- ── App menus (populated from the sketchybar menus helper when present) ──
ybar.add_event("glass_update_menus")
local MENUS_BIN = os.getenv("HOME")
  .. "/Documents/Development/sketchybar-setup/config/helpers/menus/bin/menus"
local max_menus = 12
local menu_items = {}
for i = 1, max_menus do
  local m = ybar.add("item", "glass.menu." .. i, "left")
  m:set({
    drawing = false,
    icon = { drawing = false },
    ["label.font"] = (i == 1) and "SF Pro:Heavy:13.0" or "SF Pro:Semibold:13.0",
    ["label.padding_left"] = 6,
    ["label.padding_right"] = 6,
    click_script = "'" .. MENUS_BIN:gsub("'", "'\\''") .. "' -s " .. i,
  })
  hoverable(m)
  menu_items[i] = m
end

local menus_observer = ybar.add("item", "glass.menus.observer", "left")
menus_observer:set({ drawing = false, updates = true })
menus_observer:subscribe("glass_update_menus", function()
  ybar.exec("'" .. MENUS_BIN:gsub("'", "'\\''") .. "' -l 2>/dev/null", function(menus)
    ybar.set("/glass\\.menu\\..*/", { drawing = false })
    local i = 1
    for menu in menus:gmatch("[^\r\n]+") do
      if i > max_menus then break end
      menu_items[i]:set({ label = menu, drawing = true })
      i = i + 1
    end
  end)
end)

front:subscribe("mouse.clicked", function()
  menus_visible = not menus_visible
  if menus_visible then
    ybar.set("/glass\\.space\\..*/", { drawing = false })
    ybar.trigger("glass_update_menus")
  else
    ybar.set("/glass\\.menu\\..*/", { drawing = false })
    query_focus_and_refresh()
  end
end)

-- ══ RIGHT (sketchybar order, rightmost first): calendar+time, wifi, cpu ══

-- Calendar: icon = date (Black), label = time (SF Mono) — sketchybar's item.
local cal = ybar.add("item", "glass.calendar", "right")
cal:set({
  ["icon.font"] = "SF Pro:Black:12.0",
  ["icon.padding_left"] = 8,
  label = { width = 75, align = "right", padding_right = 8 },
  ["label.font"] = "SF Mono:Regular:13.0",
  update_freq = 30,
  icon = os.date("%a. %d %b."),
})
cal:subscribe({ "routine", "forced", "system_woke" }, function()
  cal:set({ icon = os.date("%a. %d %b."), label = os.date("%I:%M %p") })
end)
cal:subscribe("mouse.clicked", function(env)
  if env.BUTTON == "right" then ybar.exec("open -a Calendar") end
end)
hoverable(cal)

-- Wi-Fi connection
local wifi = ybar.add("item", "glass.wifi", "right")
wifi:set({
  icon = "sf:wifi",
  ["icon.padding_left"] = 9,
  ["icon.padding_right"] = 9,
  label = { drawing = false },
})
wifi:subscribe("wifi_change", function(env)
  local connected = env.INFO ~= ""
  wifi:set({
    icon = connected and "sf:wifi" or "sf:wifi.slash",
    ["icon.color"] = connected and glass.text or glass.red,
  })
end)
hoverable(wifi)

-- CPU monitor: graph + tiny label, sketchybar sizing.
local cpu = ybar.add("graph", "glass.cpu", "right", 42)
cpu:set({
  icon = "sf:cpu",
  ["icon.font.size"] = 13,
  ["icon.padding_left"] = 8,
  ["icon.padding_right"] = 4,
  ["label.font"] = "SF Mono:Bold:9.0",
  ["label.color"] = glass.dim,
  ["label.padding_right"] = 8,
  graph = { color = glass.blue },
  background = { height = ITEM_H },
})
cpu:subscribe("system_stats", function(env)
  local load = tonumber(env.CPU_USAGE) or 0
  cpu:push({ load / 100 })
  local color = glass.blue
  if load > 80 then color = glass.red
  elseif load > 60 then color = glass.yellow
  elseif load > 30 then color = glass.green end
  cpu:set({ graph = { color = color }, label = "cpu " .. load .. "%" })
end)
hoverable(cpu)

-- ── Boot population ──────────────────────────────────────────────────────
ybar.update()
ybar.trigger("wifi_change")
ybar.exec("true", function() query_focus_and_refresh() end)
