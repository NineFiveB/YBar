local colors = require("colors")
local mac = require("helpers.mac")

-- Right side, rightmost first: clock, battery, volume, wifi. Bare glyphs
-- and quiet text only — no capsules, wide breathing room.

-- Clock (rightmost): gold time, nothing else.
local clock = sbar.add("item", "rosepine.clock", {
  position = "right",
  click_script = mac.CALENDAR,
  update_freq = 20,
  icon = { drawing = false },
  label = { color = colors.gold },
})
clock:subscribe({ "forced", "routine", "system_woke" }, function()
  clock:set({ label = os.date("%H:%M") })
end)

-- Battery: foam glyph by decile, muted percent; pmset fallback when the
-- event payload carries no level.
local BATT = {
  "\u{F007A}", "\u{F007B}", "\u{F007C}", "\u{F007D}", "\u{F007E}",
  "\u{F007F}", "\u{F0080}", "\u{F0081}", "\u{F0082}", "\u{F0079}",
}
local function batt_glyph(level)
  local idx = math.max(1, math.min(10, math.floor(level / 10 + 0.5)))
  return BATT[idx]
end

local battery = sbar.add("item", "rosepine.battery", {
  position = "right",
  click_script = mac.BATTERY_SETTINGS,
  icon = { string = "\u{F0079}", color = colors.foam },
  label = { color = colors.muted },
})
local function battery_render(level)
  battery:set({
    icon = { string = batt_glyph(level) },
    label = { string = level .. "%" },
  })
end
battery:subscribe({ "forced", "routine", "battery_change", "power_source_change" }, function()
  mac.battery(function(level, charging)
    battery_render(level)
    if charging then battery:set({ icon = { string = "\u{F0084}" } }) end
  end)
end)

-- Volume: rose glyph, muted percent.
local volume = sbar.add("item", "rosepine.volume", {
  position = "right",
  icon = { string = "\u{F057E}", color = colors.rose },
  label = { color = colors.muted },
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

-- Wifi: a single iris glyph, no label ever.
local wifi = sbar.add("item", "rosepine.wifi", {
  position = "right",
  icon = { string = "\u{F0928}", color = colors.iris },
  label = { drawing = false },
  click_script = "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'",
})
wifi:subscribe("wifi_change", function(env)
  local up = (env.INFO or "") ~= ""
  wifi:set({
    icon = {
      string = up and "\u{F0928}" or "\u{F092D}",
      color = up and colors.iris or colors.muted,
    },
  })
end)

sbar.trigger("wifi_change")
