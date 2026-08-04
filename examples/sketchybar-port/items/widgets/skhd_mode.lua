local colors = require("colors")
local settings = require("settings")

-- skhd mode indicator: shows the active hotkey mode (resize, window, ...)
-- as a highlighted pill, hidden in the default mode. Driven entirely by the
-- skhd_mode_changed event — each skhdrc mode entry triggers it (see
-- examples/yabai-skhd/skhdrc), so the widget stays dormant without skhd.
sbar.add("event", "skhd_mode_changed")

local mode = sbar.add("item", "widgets.skhd_mode", {
  position = "right",
  drawing = false,
  -- The when_shown default never delivers the revealing event to an
  -- initially-hidden item.
  updates = true,
  icon = {
    string = "sf:keyboard",
    color = 0xff1c1c1e,
    padding_left = 8,
    padding_right = 2,
  },
  label = {
    color = 0xff1c1c1e,
    padding_left = 2,
    padding_right = 8,
  },
  padding_left = 2,
  padding_right = 2,
  -- Inverted pill: modal state should read as an alert, not blend in.
  background = { color = colors.white, height = 26 },
})

local mode_padding = sbar.add("item", "widgets.skhd_mode.padding", {
  position = "right",
  width = settings.group_paddings,
  drawing = false,
})

mode:subscribe("skhd_mode_changed", function(env)
  local name = env.MODE or ""
  local show = name ~= "" and name ~= "default"
  mode:set({
    drawing = show,
    label = { string = name:upper() },
  })
  mode_padding:set({ drawing = show })
end)
