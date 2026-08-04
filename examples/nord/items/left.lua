local colors = require("colors")

-- After the workspaces: the frontmost application name in frost blue,
-- plain text straight on the bar (waybar's window module).

sbar.add("item", "nord.left.pad", { position = "left", width = 10 })

local front = sbar.add("item", "nord.front_app", {
  position = "left",
  icon = { drawing = false },
  label = { color = colors.frost, padding_left = 4, padding_right = 6 },
})
front:subscribe("front_app_switched", function(env)
  local name = env.INFO or ""
  front:set({ drawing = name ~= "", label = { string = name } })
end)
-- Boot state: the trigger routes through the daemon's forced query, which
-- fills INFO with the actual frontmost app.
sbar.trigger("front_app_switched")
