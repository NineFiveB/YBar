local colors = require("colors")

-- Right side, rightmost first: clock, battery, volume, wifi. Plain
-- accent-colored text straight on the island — no capsules, no
-- separators, 10pt of air between modules.

local clock = sbar.add("item", "tokyonight.clock", {
  position = "right",
  update_freq = 20,
  icon = { string = "\u{F0954}", color = colors.blue },
  label = { color = colors.blue },
})
clock:subscribe({ "forced", "routine", "system_woke" }, function()
  clock:set({ label = os.date("%H:%M") })
end)

sbar.add("item", "tokyonight.pad1", { position = "right", width = 10 })

local battery = sbar.add("item", "tokyonight.battery", {
  position = "right",
  icon = { string = "\u{F0079}", color = colors.green },
  label = { color = colors.green },
})
local function set_battery(level)
  local color = level > 20 and colors.green or colors.red
  battery:set({
    icon = { color = color },
    label = { string = level .. "%", color = color },
  })
end
battery:subscribe({ "forced", "battery_change", "power_source_change" }, function(env)
  local pct = tonumber(env.INFO) or tonumber((env.INFO or ""):match("%d+")) or nil
  if not pct then
    sbar.exec("pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%'", function(out)
      set_battery(tonumber(out:match("%d+")) or 0)
    end)
    return
  end
  set_battery(pct)
end)

sbar.add("item", "tokyonight.pad2", { position = "right", width = 10 })

local volume = sbar.add("item", "tokyonight.volume", {
  position = "right",
  icon = { string = "\u{F057E}", color = colors.purple },
  label = { color = colors.purple },
})
volume:subscribe("volume_change", function(env)
  local level = tonumber(env.INFO) or 0
  local glyph = level == 0 and "\u{F0581}"
    or (level < 40 and "\u{F057F}" or (level < 75 and "\u{F0580}" or "\u{F057E}"))
  volume:set({ icon = { string = glyph }, label = { string = level .. "%" } })
end)

sbar.trigger("volume_change")

sbar.add("item", "tokyonight.pad3", { position = "right", width = 10 })

local wifi = sbar.add("item", "tokyonight.wifi", {
  position = "right",
  icon = { string = "\u{F0928}", color = colors.blue },
  label = { drawing = false, color = colors.blue },
  click_script = "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'",
})
wifi:subscribe("wifi_change", function(env)
  local info = env.INFO or ""
  local up = info ~= ""
  wifi:set({
    icon = {
      string = up and "\u{F0928}" or "\u{F092D}",
      color = up and colors.blue or colors.muted,
    },
    label = { drawing = up and info ~= "connected", string = info },
  })
end)

sbar.trigger("wifi_change")
