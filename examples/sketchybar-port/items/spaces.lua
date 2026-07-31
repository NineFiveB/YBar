local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

-- AeroSpace integration ------------------------------------------------------
-- AeroSpace uses virtual workspaces (not native macOS Spaces), so this widget
-- talks to the `aerospace` CLI instead of yabai. ~/.aerospace.toml triggers the
-- `aerospace_workspace_change` event below via exec-on-workspace-change.
sbar.add("event", "aerospace_workspace_change")

-- Discover every workspace AeroSpace knows about (synchronous, runs once at
-- config load). Persistent workspaces that are empty are hidden until they
-- contain a window or become focused (see update_spaces).
local function aerospace_workspaces()
  local list = {}
  local handle = io.popen("aerospace list-workspaces --all 2>/dev/null")
  if handle then
    for line in handle:lines() do
      local ws = line:match("^%s*(.-)%s*$")
      if ws ~= "" then list[#list + 1] = ws end
    end
    handle:close()
  end
  return list
end

local workspaces = aerospace_workspaces()

local spaces = {}    -- sid -> space item
local brackets = {}  -- sid -> bracket item

for _, sid in ipairs(workspaces) do
  local space = sbar.add("item", "space." .. sid, {
    icon = {
      font = { family = settings.font.numbers },
      string = sid,
      padding_left = 8,
      padding_right = 4,
      color = colors.white,
      highlight_color = colors.red,
    },
    label = {
      padding_right = 8,
      padding_left = 4,
      color = colors.grey,
      highlight_color = colors.white,
      font = "sketchybar-app-font:Regular:16.0",
      y_offset = -1,
      drawing = false,
    },
    padding_right = 1,
    padding_left = 1,
    background = {
      color = colors.bg1,
      border_width = 1,
      height = 26,
      border_color = colors.black,
    },
    popup = { background = { border_width = 5, border_color = colors.black } },
    -- Left click focuses the workspace via AeroSpace.
    click_script = "aerospace workspace " .. sid,
    drawing = false,
  })

  spaces[sid] = space

  -- Single item bracket for space items to achieve double border on highlight
  brackets[sid] = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      border_width = 2,
    },
  })

  -- Padding space (visibility tracks the workspace item).
  sbar.add("item", "space.padding." .. sid, {
    script = "",
    width = settings.group_paddings,
    drawing = false,
  })
end

-- Fetch the app icons for a workspace and render them as the space label.
local function update_windows(sid)
  sbar.exec(
    "aerospace list-windows --workspace " .. sid .. " --format '%{app-name}' 2>/dev/null",
    function(windows)
      local icon_line = ""
      local seen = {}
      for raw_app in windows:gmatch("[^\r\n]+") do
        local app = raw_app:match("^%s*(.-)%s*$")
        if app ~= "" and not seen[app] then
          seen[app] = true
          local lookup = app_icons[app]
          local icon = ((lookup == nil) and app_icons["Default"] or lookup)
          icon_line = icon_line .. icon .. " "
        end
      end

      local space = spaces[sid]
      if not space then return end
      if icon_line == "" then
        space:set({
          label = { drawing = false },
          icon = { padding_left = 12, padding_right = 12 },
        })
      else
        space:set({
          label = { drawing = true, string = icon_line, padding_right = 8, padding_left = 4 },
          icon = { padding_left = 8, padding_right = 4 },
        })
      end
    end
  )
end

-- Refresh which workspaces are visible/highlighted. Visible = non-empty OR the
-- focused workspace; highlighted = focused.
-- YBAR PORT: right after wake (or login) the AeroSpace server can take a few
-- seconds to answer, and an empty reply means "not ready", not "no
-- workspaces" — hiding every space on it would blank the bar until the next
-- manual switch. Retry a few times instead.
local function update_spaces(focused, attempt)
  sbar.exec("aerospace list-workspaces --monitor all --empty no 2>/dev/null", function(nonempty)
    local visible = {}
    for raw_ws in nonempty:gmatch("[^\r\n]+") do
      local ws = raw_ws:match("^%s*(.-)%s*$")
      if ws ~= "" then visible[ws] = true end
    end
    if next(visible) == nil and (attempt or 0) < 5 then
      sbar.exec("sleep 2", function() update_spaces(focused, (attempt or 0) + 1) end)
      return
    end
    if focused and focused ~= "" then visible[focused] = true end

    for sid, space in pairs(spaces) do
      local show = visible[sid] == true
      local selected = (sid == focused)
      space:set({
        drawing = show,
        icon = { highlight = selected },
        label = { highlight = selected },
        background = { border_color = selected and colors.black or colors.bg2 },
      })
      brackets[sid]:set({
        background = { border_color = selected and colors.grey or colors.bg2 },
      })
      sbar.set("space.padding." .. sid, { drawing = show })
      if show then update_windows(sid) end
    end
  end)
end

local space_observer = sbar.add("item", {
  drawing = false,
  updates = true,
})

-- AeroSpace passes FOCUSED_WORKSPACE through the triggered event.
-- MENUS_VISIBLE (set by menus.lua) guards every refresh path so a resync
-- can't resurrect the workspace pills while the app menus are shown.
space_observer:subscribe("aerospace_workspace_change", function(env)
  if MENUS_VISIBLE then return end
  update_spaces(env.FOCUSED_WORKSPACE)
end)

-- Query the focused workspace and repaint — used for the initial paint and
-- the post-wake resync, with retries while AeroSpace is still starting up.
local function query_and_update(attempt)
  sbar.exec("aerospace list-workspaces --focused 2>/dev/null", function(focused)
    focused = focused:gsub("%s+", "")
    if focused == "" and (attempt or 0) < 5 then
      sbar.exec("sleep 2", function() query_and_update((attempt or 0) + 1) end)
      return
    end
    if MENUS_VISIBLE then return end
    update_spaces(focused)
  end)
end

-- YBAR PORT: AeroSpace only fires exec-on-workspace-change on real switches,
-- so nothing repaints after sleep and the pills stay stale or hidden —
-- resync on the daemon's system_woke event.
space_observer:subscribe("system_woke", function() query_and_update() end)

-- Initial paint at config load.
query_and_update()

local spaces_indicator = sbar.add("item", {
  padding_left = -3,
  padding_right = 0,
  icon = {
    padding_left = 8,
    padding_right = 9,
    color = colors.grey,
    string = icons.switch.on,
  },
  label = {
    width = 0,
    padding_left = 0,
    padding_right = 8,
    string = "Spaces",
    color = colors.bg1,
  },
  background = {
    color = colors.with_alpha(colors.grey, 0.0),
    border_color = colors.with_alpha(colors.bg1, 0.0),
  }
})

spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
  local currently_on = spaces_indicator:query().icon.value == icons.switch.on
  spaces_indicator:set({
    icon = currently_on and icons.switch.off or icons.switch.on
  })
end)

spaces_indicator:subscribe("mouse.entered", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 1.0 },
        border_color = { alpha = 1.0 },
      },
      icon = { color = colors.bg1 },
      label = { width = "dynamic" }
    })
  end)
end)

spaces_indicator:subscribe("mouse.exited", function(env)
  sbar.animate("tanh", 30, function()
    spaces_indicator:set({
      background = {
        color = { alpha = 0.0 },
        border_color = { alpha = 0.0 },
      },
      icon = { color = colors.grey },
      label = { width = 0, }
    })
  end)
end)

spaces_indicator:subscribe("mouse.clicked", function(env)
  sbar.trigger("swap_menus_and_spaces")
end)
