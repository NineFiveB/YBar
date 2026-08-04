local colors = require("colors")

-- Right side, added rightmost-first: clock (purple), battery (orange, red
-- when low), volume (green), wifi (cyan). Every module is its own bright
-- rounded block with dark text; 6pt pads separate the blocks.

-- Clock (rightmost): purple block.
local clock = sbar.add("item", "dracula.clock", {
  position = "right",
  update_freq = 20,
  icon = { string = "\u{F0954}", color = colors.bg },
  label = { color = colors.bg },
  background = { color = colors.purple, corner_radius = 8, height = 24 },
})
clock:subscribe({ "forced", "routine", "system_woke" }, function()
  clock:set({ label = os.date("%H:%M") })
end)

sbar.add("item", "dracula.right.pad1", { position = "right", width = 6 })

-- Battery: orange block, red block at 15% or below.
local battery = sbar.add("item", "dracula.battery", {
  position = "right",
  update_freq = 180,
  icon = { string = "\u{F0079}", color = colors.bg },
  label = { color = colors.bg },
  background = { color = colors.orange, corner_radius = 8, height = 24 },
})

local function battery_glyph(level)
  if level >= 95 then return "\u{F0079}" end
  local glyphs = {
    "\u{F007A}", "\u{F007B}", "\u{F007C}", "\u{F007D}", "\u{F007E}",
    "\u{F007F}", "\u{F0080}", "\u{F0081}", "\u{F0082}",
  }
  return glyphs[math.min(math.max(math.floor(level / 10), 1), 9)]
end

local function render_battery(level)
  battery:set({
    icon = { string = battery_glyph(level) },
    label = { string = level .. "%" },
    background = { color = level <= 15 and colors.red or colors.orange },
  })
end

battery:subscribe({ "forced", "routine", "battery_change", "power_source_change", "system_woke" }, function(env)
  local pct = tonumber(env.INFO) or tonumber((env.INFO or ""):match("%d+"))
  if pct then
    render_battery(pct)
    return
  end
  -- Fallback: no INFO on this event, ask pmset.
  sbar.exec("pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%'", function(out)
    render_battery(tonumber(out:match("%d+")) or 0)
  end)
end)

sbar.add("item", "dracula.right.pad2", { position = "right", width = 6 })

-- Volume: green block.
local volume = sbar.add("item", "dracula.volume", {
  position = "right",
  icon = { string = "\u{F057E}", color = colors.bg },
  label = { color = colors.bg },
  background = { color = colors.green, corner_radius = 8, height = 24 },
})
volume:subscribe("volume_change", function(env)
  local level = tonumber(env.INFO) or 0
  local glyph = level == 0 and "\u{F0581}"
    or (level < 33 and "\u{F057F}" or (level < 66 and "\u{F0580}" or "\u{F057E}"))
  volume:set({ icon = { string = glyph }, label = { string = level .. "%" } })
end)

sbar.trigger("volume_change")

sbar.add("item", "dracula.right.pad3", { position = "right", width = 6 })

-- Wifi: cyan block; SSID as the label when known.
local wifi = sbar.add("item", "dracula.wifi", {
  position = "right",
  icon = { string = "\u{F0928}", color = colors.bg },
  label = { drawing = false, color = colors.bg },
  background = { color = colors.cyan, corner_radius = 8, height = 24 },
  click_script = "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'",
})
wifi:subscribe("wifi_change", function(env)
  local info = env.INFO or ""
  local up = info ~= ""
  wifi:set({
    icon = {
      string = up and "\u{F0928}" or "\u{F092D}",
      padding_right = (up and info ~= "connected") and 4 or 8,
    },
    label = { drawing = up and info ~= "connected", string = info },
  })
end)

sbar.trigger("wifi_change")
