local colors = require("colors")

-- Left capsule: clock | network | bluetooth — one segmented pill (a bracket
-- supplies the shared capsule, per-module accents color the contents), then
-- the focused window title as an inverted light pill.

local clock = sbar.add("item", "darxk.clock", {
  position = "left",
  update_freq = 20,
  icon = { string = "", color = colors.peach },
  label = { color = colors.peach },
})
clock:subscribe({ "forced", "routine", "system_woke" }, function()
  clock:set({ label = os.date("%H:%M") })
end)

local net = sbar.add("item", "darxk.network", {
  position = "left",
  icon = { string = "󰤨", color = colors.yellow },
  label = { drawing = false },
  click_script = "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'",
})
net:subscribe("wifi_change", function(env)
  local info = env.INFO or ""
  local up = info ~= ""
  net:set({
    icon = { string = up and "󰤨" or "󰤭" },
    label = { drawing = up and info ~= "connected", string = info },
  })
end)

sbar.trigger("wifi_change")

local bt = sbar.add("item", "darxk.bluetooth", {
  position = "left",
  icon = { string = "󰂯", color = colors.blue },
  label = { drawing = false },
  click_script = "open 'x-apple.systempreferences:com.apple.BluetoothSettings'",
})

sbar.add("bracket", "darxk.left.capsule", { clock.name, net.name, bt.name }, {
  background = { color = colors.pill, corner_radius = 17, height = 26 },
})

sbar.add("item", "darxk.left.pad", { position = "left", width = 12 })

-- Focused window: light pill, dark text (waybar's #window).
local front = sbar.add("item", "darxk.window", {
  position = "left",
  icon = { drawing = false },
  label = { color = colors.text_dark, padding_left = 10, padding_right = 10 },
  background = { color = colors.light, corner_radius = 17, height = 26 },
})
front:subscribe("front_app_switched", function(env)
  local name = env.INFO or ""
  front:set({ drawing = name ~= "", label = { string = name } })
end)
-- Boot state: the trigger routes through the daemon's forced query, which
-- fills INFO with the actual frontmost app.
sbar.trigger("front_app_switched")
