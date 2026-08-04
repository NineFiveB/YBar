local colors = require("colors")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

-- Claude Code agent indicator (minimal so-agentbar): a pill with the Claude
-- glyph and the number of active agent sessions. Bright while any session is
-- streaming right now, dimmed when merely recent, hidden when none.
local probe = SKETCHYBAR_CONFIG .. "/helpers/claude_agents.sh"

local claude = sbar.add("item", "widgets.claude", {
  position = "right",
  drawing = false,
  updates = true,
  update_freq = 5,
  icon = {
    string = app_icons["Claude"],
    font = "sketchybar-app-font:Regular:16.0",
    color = colors.grey,
    padding_left = 8,
    padding_right = 2,
  },
  label = {
    font = { family = settings.font.numbers },
    color = colors.grey,
    padding_left = 2,
    padding_right = 8,
  },
  padding_left = 2,
  padding_right = 2,
})

sbar.add("bracket", "widgets.claude.bracket", { claude.name }, {
  background = { color = colors.bg1 },
})

local claude_padding = sbar.add("item", "widgets.claude.padding", {
  position = "right",
  width = settings.group_paddings,
  drawing = false,
})

-- Circular spinner beside the count while any session is streaming.
local spinner = require("helpers.spinner").attach(claude, { size = 12 })

local function refresh()
  sbar.exec("'" .. probe:gsub("'", "'\\''") .. "'", function(out)
    local active, working = out:match("(%d+)%s+(%d+)")
    active = tonumber(active) or 0
    working = tonumber(working) or 0
    local show = active > 0
    local color = working > 0 and colors.white or colors.grey
    claude:set({
      drawing = show,
      icon = { color = color },
      label = { string = tostring(active), color = color },
    })
    claude_padding:set({ drawing = show })
    if show and working > 0 then spinner.start() else spinner.stop() end
  end)
end

claude:subscribe({ "routine", "system_woke" }, refresh)
refresh()
