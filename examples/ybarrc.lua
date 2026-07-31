-- Example YbarLua config. Install:
--   mkdir -p ~/.config/ybar && cp examples/ybarrc.lua ~/.config/ybar/ybarrc.lua
--
-- Runs *inside* the daemon: callbacks are direct Lua function calls —
-- no IPC round-trips, no process spawns (compare SbarLua, which still talks
-- to sketchybar over a mach port, and shell configs which fork per event).
--
-- Property tables nest (`background = { height = 16 }`) or use dotted keys
-- (`["icon.color"] = ...`) — both flatten onto the same namespace. Note that
-- Lua tables silently drop duplicate keys, so `icon = "sf:cpu"` and
-- `icon = { color = ... }` in ONE table would collide: use a dotted key for
-- the second.

ybar.bar({
  height = 32,
  color = "0xee1e1e2e",
  topmost = "on",
})

ybar.default({
  icon = { color = "0xffcdd6f4", padding_left = 8, padding_right = 4 },
  label = { color = "0xffcdd6f4", padding_right = 8 },
})

-- ── Clock: routine timer -> direct callback ──────────────────────────────
local clock = ybar.add("item", "clock", "right")
clock:set({
  icon = "sf:clock",
  update_freq = 10,
  label = os.date("%a %d %H:%M"),
})
clock:subscribe("routine", function()
  clock:set({ label = os.date("%a %d %H:%M") })
end)

-- ── Front app ────────────────────────────────────────────────────────────
local front = ybar.add("item", "front_app", "left")
front:set({
  icon = "sf:macwindow",
  ["icon.color"] = "0xff89b4fa",
  padding_left = 10,
})
front:subscribe("front_app_switched", function(env)
  front:set({ label = env.INFO })
end)

-- ── CPU graph fed by the built-in stats provider, zero shell-outs ────────
local cpu = ybar.add("graph", "cpu", "right", 60)
cpu:set({
  icon = "sf:cpu",
  ["icon.color"] = "0xfff9e2af",
  background = { height = 16 },
  graph = { color = "0xffa6e3a1" },
})
cpu:subscribe("system_stats", function(env)
  cpu:push({ tonumber(env.CPU_FRACTION) or 0 })
  cpu:set({ label = env.CPU_USAGE .. "%" })
end)

-- ── Volume slider: drags call straight back into Lua ─────────────────────
local vol = ybar.add("slider", "vol", "right", 90)
vol:set({
  icon = "sf:speaker.wave.2.fill",
  ["icon.color"] = "0xff89b4fa",
  slider = {
    percentage = 50,
    highlight_color = "0xff89b4fa",
    background = { color = "0xff45475a" },
  },
})
vol:subscribe("mouse.clicked", function(env)
  if env.PERCENTAGE then
    ybar.exec("osascript -e 'set volume output volume " .. env.PERCENTAGE .. "'")
  end
end)
vol:subscribe("volume_change", function(env)
  vol:set({ slider = { percentage = env.INFO } })
end)

-- ── Bracketed group (front app + date) hosting a popup ───────────────────
local date = ybar.add("item", "date", "left")
date:set({
  label = os.date("%a %d"),
  ["label.color"] = "0xfff38ba8",
})
local group = ybar.add("bracket", "clockgroup", { "front_app", "date" })
group:set({
  background = { color = "0xff313244", corner_radius = 9, height = 24 },
})
group:subscribe("mouse.clicked", function()
  group:set({ popup = { drawing = "toggle" } })
end)

local cal = ybar.add("item", "popup_cal", "popup.clockgroup")
cal:set({ icon = "sf:calendar", label = "Open Calendar" })
cal:subscribe("mouse.clicked", function()
  ybar.exec("open -a Calendar")
  group:set({ popup = { drawing = "off" } })
end)

-- Animated color change: the animation bridge from Lua.
ybar.animate("tanh", 45, function()
  clock:set({ ["label.color"] = "0xff89b4fa" })
end)
