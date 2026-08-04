local colors = require("colors")

-- Left, after the workspaces: the frontmost app in a purple block with
-- dark text.

sbar.add("item", "dracula.left.pad", { position = "left", width = 6 })

local front = sbar.add("item", "dracula.front_app", {
  position = "left",
  icon = { drawing = false },
  label = { color = colors.bg, padding_left = 10, padding_right = 10 },
  background = { color = colors.purple, corner_radius = 8, height = 24 },
})
front:subscribe("front_app_switched", function(env)
  local name = env.INFO or ""
  front:set({ drawing = name ~= "", label = { string = name } })
end)
-- Boot state: the trigger routes through the daemon's forced query, which
-- fills INFO with the actual frontmost app.
sbar.trigger("front_app_switched")
