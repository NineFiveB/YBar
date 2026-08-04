local colors = require("colors")

-- Center: the frontmost app in plain foreground text, a now-playing
-- marquee beside it (green music note, hidden when nothing plays).

local front = sbar.add("item", "tokyonight.front_app", {
  position = "center",
  icon = { drawing = false },
  label = { color = colors.fg, padding_left = 4, padding_right = 4 },
})
front:subscribe("front_app_switched", function(env)
  local name = env.INFO or ""
  front:set({ drawing = name ~= "", label = { string = name } })
end)
-- Boot state: the trigger routes through the daemon's forced query, which
-- fills INFO with the actual frontmost app.
sbar.trigger("front_app_switched")

local media = sbar.add("item", "tokyonight.media", {
  position = "center",
  drawing = false,
  updates = true,   -- starts hidden, must keep receiving media_change
  scroll_texts = true,
  icon = { string = "\u{F075A}", color = colors.green, padding_left = 8 },
  label = { width = 130, color = colors.fg },
})
local media_app = nil
media:subscribe("media_change", function(env)
  local state = env.MEDIA_STATE or ""
  local show = state == "playing" or state == "paused"
  media_app = env.MEDIA_APP
  local artist = env.MEDIA_ARTIST or ""
  local title = env.MEDIA_TITLE or ""
  media:set({
    drawing = show,
    label = {
      string = (artist ~= "" and (artist .. " - ") or "") .. title,
      color = state == "playing" and colors.fg or colors.muted,
    },
  })
end)
media:subscribe("mouse.clicked", function()
  if media_app then
    sbar.exec("osascript -e 'tell application \"" .. media_app .. "\" to playpause'")
  end
end)
