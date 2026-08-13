local colors = require("colors")
local settings = require("settings")

local front_app = sbar.add("item", "front_app", {
  display = "active",
  -- No app icon by request — the name label alone identifies the app.
  icon = { drawing = false },
  image = { drawing = false },
  label = {
    font = {
      style = settings.font.style_map["Black"],
      size = 12.0,
    },
  },
  updates = true,
})

front_app:subscribe("front_app_switched", function(env)
  front_app:set({ label = { string = env.INFO } })
end)

-- The macOS click swaps the pills for the focused app's menu titles
-- (items/menus.lua) — no Windows concept, so the click does nothing here.
