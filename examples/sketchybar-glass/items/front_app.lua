local colors = require("colors")
local settings = require("settings")

local front_app = sbar.add("item", "front_app", {
  display = "active",
  -- The engine resolves real shell icons: image = "app.<Name>" shows the
  -- focused app's own icon (the macOS tree used an icon font instead).
  icon = { drawing = false },
  label = {
    font = {
      style = settings.font.style_map["Black"],
      size = 12.0,
    },
  },
  updates = true,
})

front_app:subscribe("front_app_switched", function(env)
  front_app:set({
    label = { string = env.INFO },
    image = { string = "app." .. env.INFO, size = 16, drawing = true },
  })
end)

-- The macOS click swaps the pills for the focused app's menu titles
-- (items/menus.lua) — no Windows concept, so the click does nothing here.
