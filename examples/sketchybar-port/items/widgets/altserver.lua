local colors = require("colors")
local settings = require("settings")

local config_dir = SKETCHYBAR_CONFIG  -- YBAR PORT: helpers live in the original tree
local click_script = config_dir .. "/helpers/altserver_click.sh"

-- AltServer icon (SF Symbol: iphone.and.arrow.forward)
local altserver_icon = "􁣡"

local altserver = sbar.add("item", "widgets.altserver", {
  position = "right",
  icon = {
    string = altserver_icon,
    font = { style = settings.font.style_map["Regular"], size = 16.0 },
    color = colors.green,
    width = 27,
    align = "center",
  },
  label = { drawing = false },
  padding_left = 4,
  padding_right = 4,
  click_script = "'" .. click_script:gsub("'", "'\\''") .. "'",
})

sbar.add("bracket", "widgets.altserver.bracket", { altserver.name }, {
  background = { color = colors.bg1 },
})

sbar.add("item", "widgets.altserver.padding", {
  position = "right",
  width = settings.group_paddings,
})

-- Dim icon when AltServer is not running, bright green when it is
local function check_running()
  sbar.exec("pgrep -x AltServer >/dev/null 2>&1 && echo running || echo stopped",
    function(output)
      local running = output:match("running")
      altserver:set({
        icon = {
          color = running and colors.green or colors.grey,
        },
      })
    end)
end

altserver:subscribe("routine", check_running)
altserver:subscribe("forced", check_running)
