local colors = require("colors")

-- Right side, waybar order: media, hardware capsule (thermal | battery),
-- audio capsule (volume). Right-position items are added rightmost-first.

-- Audio capsule (rightmost).
local volume = sbar.add("item", "darxk.volume", {
  position = "right",
  icon = { string = "󰕾", color = colors.blue },
  label = { color = colors.blue },
})
volume:subscribe("volume_change", function(env)
  local level = tonumber(env.INFO) or 0
  local glyph = level == 0 and "󰖁" or (level < 40 and "󰕿" or (level < 75 and "󰖀" or "󰕾"))
  volume:set({ icon = { string = glyph }, label = { string = level .. "%" } })
end)

sbar.trigger("volume_change")

sbar.add("bracket", "darxk.audio.capsule", { volume.name }, {
  background = { color = colors.pill, corner_radius = 17, height = 26 },
})

sbar.add("item", "darxk.right.pad", { position = "right", width = 10 })

-- Hardware capsule: thermal state | battery.
local battery = sbar.add("item", "darxk.battery", {
  position = "right",
  icon = { string = "󰁹", color = colors.green },
  label = { color = colors.green },
})
battery:subscribe({ "forced", "battery_change", "power_source_change" }, function(env)
  local pct = tonumber(env.INFO) or tonumber((env.INFO or ""):match("%d+")) or nil
  if not pct then
    sbar.exec("pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%'", function(out)
      local level = tonumber(out:match("%d+")) or 0
      local color = level > 30 and colors.green or (level > 15 and colors.warn or colors.red)
      battery:set({
        icon = { color = color },
        label = { string = level .. "%", color = color },
      })
    end)
    return
  end
  local color = pct > 30 and colors.green or (pct > 15 and colors.warn or colors.red)
  battery:set({ icon = { color = color }, label = { string = pct .. "%", color = color } })
end)

local thermal = sbar.add("item", "darxk.thermal", {
  position = "right",
  updates = true,
  update_freq = 10,
  icon = { string = "󰔏", color = colors.cyan, padding_left = 9 },
  label = { drawing = false },
})
thermal:subscribe("system_stats", function(env)
  local state = env.THERMAL_STATE or "nominal"
  local color = state == "nominal" and colors.cyan
    or (state == "fair" and colors.warn or colors.red)
  thermal:set({ icon = { color = color } })
end)

sbar.add("bracket", "darxk.hw.capsule", { thermal.name, battery.name }, {
  background = { color = colors.pill, corner_radius = 17, height = 26 },
})

sbar.add("item", "darxk.right.pad2", { position = "right", width = 10 })

-- Media (waybar custom/media): now-playing via the media_change event,
-- Spotify green when Spotify is the source.
local media = sbar.add("item", "darxk.media", {
  position = "right",
  drawing = false,
  updates = true,
  scroll_texts = true,
  icon = { string = "󰝚", color = colors.text },
  label = { width = 140, color = colors.text },
  background = { color = colors.pill, corner_radius = 17, height = 26 },
})
local media_app = nil
media:subscribe("media_change", function(env)
  local state = env.MEDIA_STATE or ""
  local show = state == "playing" or state == "paused"
  media_app = env.MEDIA_APP
  local accent = env.MEDIA_APP == "Spotify" and colors.spotify or colors.text
  local artist = env.MEDIA_ARTIST or ""
  local title = env.MEDIA_TITLE or ""
  media:set({
    drawing = show,
    icon = { color = accent },
    label = {
      string = (artist ~= "" and (artist .. " - ") or "") .. title,
      color = state == "playing" and colors.text or colors.warn,
    },
  })
end)
media:subscribe("mouse.clicked", function()
  if media_app then
    sbar.exec("osascript -e 'tell application \"" .. media_app .. "\" to playpause'")
  end
end)

sbar.add("item", "darxk.right.pad3", { position = "right", width = 10 })
