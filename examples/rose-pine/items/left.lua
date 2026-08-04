local colors = require("colors")

-- Focused application, whispered: lowercase iris text, no icon, no pill.
local front = sbar.add("item", "rosepine.front_app", {
  position = "left",
  icon = { drawing = false },
  label = { color = colors.iris, padding_left = 8 },
})
front:subscribe("front_app_switched", function(env)
  local name = env.INFO or ""
  front:set({ drawing = name ~= "", label = { string = string.lower(name) } })
end)
-- Boot state: the trigger routes through the daemon's forced query, which
-- fills INFO with the actual frontmost app.
sbar.trigger("front_app_switched")
