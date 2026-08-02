local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local config_dir = SKETCHYBAR_CONFIG  -- YBAR PORT: helpers live in the original tree
local menus_bin = config_dir .. "/helpers/menus/bin/menus"

-- YBAR PORT: the apple pill opens a replica of the native Apple menu
-- (left click); right click still opens the real one via the menus helper.
-- Restart/Shut Down confirm with a second click — the scripted actions
-- bypass macOS's own confirmation dialogs.

local popup_width = 230
local inset = 12

-- Padding item required because of bracket
sbar.add("item", { width = 5 })

local apple = sbar.add("item", {
  icon = {
    font = { size = 16.0 },
    string = icons.apple,
    padding_right = 8,
    padding_left = 8,
  },
  label = { drawing = false },
  background = {
    color = colors.bg2,
    border_color = colors.black,
    border_width = 1
  },
  padding_left = 1,
  padding_right = 1,
})

-- Double border for apple using a single item bracket
local apple_bracket = sbar.add("bracket", { apple.name }, {
  background = {
    color = colors.transparent,
    height = 30,
    border_color = colors.grey,
  },
  popup = { align = "left" }
})

-- Padding item required because of bracket
sbar.add("item", { width = 7 })

local popup_pos = "popup." .. apple_bracket.name

local full_name = "…"
do
  local handle = io.popen("id -F 2>/dev/null")
  if handle then
    full_name = (handle:read("*l") or "you")
    handle:close()
  end
end

local function hide_popup()
  apple_bracket:set({ popup = { drawing = false } })
end

local function add_separator()
  sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = { drawing = false },
    label = { drawing = false },
    background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
  })
end

local rows = {}          -- item handle -> definition
local confirm_armed = {} -- item handle -> true while awaiting second click

local function add_row(title, action, needs_confirm)
  local row = sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    align = "left",
    icon = {
      string = title,
      align = "left",
      color = colors.white,
      font = { size = 13.0 },
      width = popup_width - inset,
      padding_left = inset,
    },
    label = { drawing = false },
  })
  rows[row] = { title = title, action = action, confirm = needs_confirm }
  row:subscribe("mouse.clicked", function()
    local def = rows[row]
    if def.confirm and not confirm_armed[row] then
      confirm_armed[row] = true
      row:set({ icon = { string = def.title:gsub("…", "") .. " — click to confirm" } })
      return
    end
    confirm_armed[row] = nil
    row:set({ icon = { string = def.title } })
    hide_popup()
    sbar.exec(def.action)
  end)
  return row
end

local function reset_confirms()
  for row, def in pairs(rows) do
    if confirm_armed[row] then
      confirm_armed[row] = nil
      row:set({ icon = { string = def.title } })
    end
  end
end

add_row("About This Mac",
  "open 'x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension'")
add_separator()
add_row("System Settings…", "open -a 'System Settings'")
add_row("App Store…", "open -a 'App Store'")
add_separator()
add_row("Force Quit…",
  [[osascript -e 'tell application "System Events" to key code 53 using {command down, option down}']])
add_separator()
add_row("Sleep", "pmset sleepnow")
add_row("Restart…",
  [[osascript -e 'tell application "System Events" to restart']], true)
add_row("Shut Down…",
  [[osascript -e 'tell application "System Events" to shut down']], true)
add_separator()
add_row("Lock Screen",
  [[osascript -e 'tell application "System Events" to keystroke "q" using {command down, control down}']])
add_row("Log Out " .. full_name .. "…",
  [[osascript -e 'tell application "System Events" to log out']])

local function toggle_popup(env)
  if env.BUTTON == "right" then
    -- The real Apple menu, via the sketchybar menus helper.
    sbar.exec("'" .. menus_bin:gsub("'", "'\\''") .. "' -s 0")
    return
  end
  local should_draw = apple_bracket:query().popup.drawing == "off"
  if should_draw then
    reset_confirms()
    apple_bracket:set({ popup = { drawing = true } })
  else
    hide_popup()
  end
end

apple:subscribe("mouse.clicked", toggle_popup)
apple:subscribe("mouse.exited.global", function()
  reset_confirms()
  hide_popup()
end)
