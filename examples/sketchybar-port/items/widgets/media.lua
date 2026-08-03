local colors = require("colors")
local settings = require("settings")

-- Now-playing pill: appears while Music or Spotify reports playback (the
-- engine's media_change event — distributed notifications, no MediaRemote).
-- Long titles marquee-scroll inside the fixed label width; click toggles
-- play/pause in whichever app is playing.
local media = sbar.add("item", "widgets.media", {
  position = "right",
  drawing = false,
  -- updates=true: the default when_shown never delivers media_change to the
  -- initially-hidden pill, so nothing could ever reveal it.
  updates = true,
  scroll_texts = true,
  icon = {
    string = "sf:music.note",
    color = colors.grey,
    padding_left = 8,
    padding_right = 2,
  },
  label = {
    width = 150,
    color = colors.white,
    padding_left = 2,
    padding_right = 8,
  },
  padding_left = 2,
  padding_right = 2,
})

sbar.add("bracket", "widgets.media.bracket", { media.name }, {
  background = { color = colors.bg1 },
})

local media_padding = sbar.add("item", "widgets.media.padding", {
  position = "right",
  width = settings.group_paddings,
  drawing = false,
})

local current_app = nil

media:subscribe("media_change", function(env)
  local state = env.MEDIA_STATE or ""
  local playing = state == "playing"
  local show = playing or state == "paused"
  current_app = env.MEDIA_APP
  local artist = env.MEDIA_ARTIST or ""
  local title = env.MEDIA_TITLE or ""
  local text = (artist ~= "" and (artist .. " — ") or "") .. title
  local color = playing and colors.white or colors.grey
  media:set({
    drawing = show,
    icon = { color = color },
    label = { string = text, color = color },
  })
  media_padding:set({ drawing = show })
end)

media:subscribe("mouse.clicked", function()
  if current_app then
    sbar.exec("osascript -e 'tell application \"" .. current_app .. "\" to playpause'")
  end
end)
