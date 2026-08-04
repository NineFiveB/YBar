local colors = require("colors")
local mac = require("helpers.mac")

-- Right side: flat "icon value" modules straight on the strip, divided by
-- thin polar-night vertical bars. Right-position items are added
-- rightmost-first, so on screen this reads: wifi | volume | battery | clock.

local function separator(name)
  sbar.add("item", name, {
    position = "right",
    icon = { drawing = false },
    label = {
      string = "\u{2502}",
      color = colors.muted,
      padding_left = 6,
      padding_right = 6,
    },
  })
end

-- Clock (rightmost): frost icon, "%a %H:%M".
local clock = sbar.add("item", "nord.clock", {
  position = "right",
  click_script = mac.CALENDAR,
  update_freq = 20,
  icon = { string = "\u{F0954}", color = colors.frost },
  label = { color = colors.text },
})
clock:subscribe({ "forced", "routine", "system_woke" }, function()
  clock:set({ label = os.date("%a %H:%M") })
end)

separator("nord.sep1")

-- Battery: aurora green / yellow / red by level.
local battery = sbar.add("item", "nord.battery", {
  position = "right",
  click_script = mac.BATTERY_SETTINGS,
  icon = { string = "\u{F0079}", color = colors.green },
  label = { color = colors.text },
})
local function battery_paint(level)
  local color = level > 30 and colors.green
    or (level > 15 and colors.yellow or colors.red)
  battery:set({ icon = { color = color }, label = { string = level .. "%" } })
end
battery:subscribe({ "forced", "routine", "battery_change", "power_source_change" }, function()
  mac.battery(function(level, charging)
    battery_paint(level)
    if charging then battery:set({ icon = { string = "\u{F0084}" } }) end
  end)
end)

separator("nord.sep2")

-- Volume: glyph steps with level.
local volume = sbar.add("item", "nord.volume", {
  position = "right",
  icon = { string = "\u{F057E}", color = colors.frost_dim },
  label = { color = colors.text },
})
volume:subscribe("volume_change", function(env)
  local level = tonumber(env.INFO) or 0
  local glyph = level == 0 and "\u{F0581}"
    or (level < 40 and "\u{F057F}" or (level < 75 and "\u{F0580}" or "\u{F057E}"))
  volume:set({ icon = { string = glyph }, label = { string = level .. "%" } })
end)
volume:set({ click_script = mac.SOUND_SETTINGS })
mac.volume_scroll(volume)
sbar.trigger("volume_change")

separator("nord.sep3")

-- Wifi: SSID in snow-storm text when known; the daemon sends "connected"
-- when the SSID is private, and "" when the link is down.
local wifi = sbar.add("item", "nord.wifi", {
  position = "right",
  icon = { string = "\u{F0928}", color = colors.frost },
  label = { drawing = false, color = colors.text },
  click_script = "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'",
})
wifi:subscribe("wifi_change", function(env)
  local info = env.INFO or ""
  local up = info ~= ""
  wifi:set({
    icon = {
      string = up and "\u{F0928}" or "\u{F092D}",
      color = up and colors.frost or colors.muted,
    },
    label = { drawing = up and info ~= "connected", string = info },
  })
end)
sbar.trigger("wifi_change")
