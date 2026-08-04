local colors = require("colors")

-- After the workspace blocks: the focused application in plain gruvbox fg
-- text, no block behind it.
sbar.add("item", "gruvbox.left.pad", { position = "left", width = 10 })

local front = sbar.add("item", "gruvbox.front_app", {
  position = "left",
  icon = { drawing = false },
  label = { color = colors.fg, padding_left = 4, padding_right = 8 },
})
front:subscribe("front_app_switched", function(env)
  local name = env.INFO or ""
  front:set({ drawing = name ~= "", label = { string = name } })
end)
-- Boot state: the trigger routes through the daemon's forced query, which
-- fills INFO with the actual frontmost app.
sbar.trigger("front_app_switched")
