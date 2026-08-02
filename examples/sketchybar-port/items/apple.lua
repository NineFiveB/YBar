local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local config_dir = SKETCHYBAR_CONFIG  -- YBAR PORT: helpers live in the original tree
local menus_bin = config_dir .. "/helpers/menus/bin/menus"

-- YBAR PORT: replica of the macOS 26 Apple menu (left click); right click
-- opens the real one via the menus helper. Restart/Shut Down confirm with
-- a second click — the scripted actions bypass macOS's own dialogs.

local popup_width = 240
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

local full_name = "you"
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

-- Native anatomy: optional leading SF glyph, title, optional right-aligned
-- shortcut hint (grey) or submenu chevron. Glyphless titles start at the
-- left margin, exactly like the real menu.
local function add_row(title, action, opts)
  opts = opts or {}
  local right = opts.shortcut or opts.chevron
  local row = sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    align = "left",
    image = {
      string = opts.glyph or "",
      size = 16,
      padding_left = inset,
      padding_right = 8,
    },
    icon = {
      string = title,
      align = "left",
      color = colors.white,
      font = { size = 13.0 },
      padding_left = opts.glyph and 0 or inset,
      width = popup_width - 78 - (opts.glyph and (inset + 24) or inset),
    },
    label = right and {
      string = right,
      align = "right",
      color = colors.with_alpha(colors.grey, 0.9),
      font = { size = 12.0 },
      width = 78,
      padding_right = inset,
    } or { drawing = false },
  })
  rows[row] = { title = title, action = action, confirm = opts.confirm }
  row:subscribe("mouse.clicked", function()
    local def = rows[row]
    if def.confirm and not confirm_armed[row] then
      confirm_armed[row] = true
      row:set({ icon = { string = def.title .. " — confirm" } })
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

add_row("System Information",
  "open 'x-apple.systempreferences:com.apple.SystemProfiler.AboutExtension'",
  { glyph = "sf.laptopcomputer" })
add_separator()
add_row("System Settings…", "open -a 'System Settings'",
  { glyph = "sf.gearshape" })
add_row("App Store", "open -a 'App Store'",
  { glyph = "sf.storefront" })
add_separator()
local force_quit_row = add_row("Force Quit",
  [[osascript -e 'tell application "System Events" to key code 53 using {command down, option down}']],
  { shortcut = "⌥⇧⌘⎋" })
add_separator()
add_row("Sleep", "pmset sleepnow")
add_row("Restart",
  [[osascript -e 'tell application "System Events" to restart']], { confirm = true })
add_row("Shut Down",
  [[osascript -e 'tell application "System Events" to shut down']], { confirm = true })
add_separator()
add_row("Lock Screen",
  [[osascript -e 'tell application "System Events" to keystroke "q" using {command down, control down}']],
  { shortcut = "⌃⌘Q" })
add_row("Log Out " .. full_name,
  [[osascript -e 'tell application "System Events" to log out']],
  { shortcut = "⌥⇧⌘Q" })

-- "Force Quit <front app>", tracked live like the native menu.
apple:subscribe("front_app_switched", function(env)
  if env.INFO and env.INFO ~= "" then
    local def = rows[force_quit_row]
    def.title = "Force Quit " .. env.INFO
    if not confirm_armed[force_quit_row] then
      force_quit_row:set({ icon = { string = def.title } })
    end
  end
end)

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
