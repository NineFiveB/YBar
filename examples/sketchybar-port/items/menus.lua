local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

local config_dir = SKETCHYBAR_CONFIG  -- YBAR PORT: helpers live in the original tree
local menus_bin = config_dir .. "/helpers/menus/bin/menus"

-- YBAR PORT: the menus helper is an opt-in build (`make helpers` from a
-- clone; it links the private SkyLight framework, so the Homebrew formula
-- never builds it — see README.md). Probe once: without the binary neither
-- `-l` nor a click_script could run, so the menu items are not created at
-- all and the swap is a no-op, leaving a Homebrew install with a clean bar
-- instead of fifteen items that fail silently.
local function is_executable(path)
  return os.execute("test -x '" .. path:gsub("'", "'\\''") .. "'") == true
end
MENUS_HELPER_AVAILABLE = is_executable(menus_bin)

local menu_watcher = sbar.add("item", {
  drawing = false,
  updates = false,
})
local space_menu_swap = sbar.add("item", {
  drawing = false,
  updates = true,
})
sbar.add("event", "swap_menus_and_spaces")

-- YBAR PORT: spaces.lua checks this on workspace-change/wake resyncs so they
-- can't re-show the workspace pills while the app menus occupy the bar.
MENUS_VISIBLE = false

if not MENUS_HELPER_AVAILABLE then
  -- The event stays registered (spaces.lua and front_app.lua subscribe to
  -- it); with no handler here a swap leaves the pills and front_app in place.
  return menu_watcher
end

local max_items = 15
local menu_items = {}
for i = 1, max_items, 1 do
  local menu = sbar.add("item", "menu." .. i, {
    padding_left = settings.paddings,
    padding_right = settings.paddings,
    drawing = false,
    background = YSUITE_LIQUID and { drawing = false, glass = false, sheen = false } or nil,
    icon = { drawing = false },
    label = {
      font = {
        style = settings.font.style_map[YSUITE_LIQUID and "Regular" or (i == 1 and "Heavy" or "Semibold")]
      },
      padding_left = 6,
      padding_right = 6,
    },
    click_script = "'" .. menus_bin:gsub("'", "'\\''") .. "' -s " .. i,
  })

  menu_items[i] = menu
end

-- YBAR PORT: digits-only pattern — the bracket pill must end at the last
-- menu item, not swallow menu.padding (which is the gap before "Spaces").
sbar.add("bracket", { '/menu\\.[0-9]+/' }, {
  background = {
    color = YSUITE_LIQUID and colors.transparent or colors.bg1,
    drawing = not YSUITE_LIQUID,
  },
})

local menu_padding = sbar.add("item", "menu.padding", {
  drawing = false,
  width = 5
})

-- Appear/disappear animation: the menu strip grows open and collapses shut
-- (same motion language as the workspace pills). menus_shown is explicit
-- state — querying item geometry mid-animation would misread a fading strip
-- as still-open. menu_hide_seq invalidates a pending collapse cleanup when
-- the menus come back before it fires.
local menus_shown = false
local menu_hide_seq = 0

local function park_menu_item(i)
  menu_items[i]:set({
    padding_left = settings.paddings,
    padding_right = settings.paddings,
    y_offset = 0,
    label = { width = "dynamic", padding_left = 6, padding_right = 6, color = { alpha = 1.0 } },
  })
end

local function update_menus(env)
  sbar.exec("'" .. menus_bin:gsub("'", "'\\''") .. "' -l", function(menus)
    -- The swap closed (or is closing) while -l was in flight.
    if not menus_shown then return end
    sbar.set('/menu\\..*/', { drawing = false })
    menu_padding:set({ drawing = true })
    local id = 1
    for menu in string.gmatch(menus, '[^\r\n]+') do
      if id <= max_items then
        menu_items[id]:set({
          drawing = true,
          padding_left = 0,
          padding_right = 0,
          y_offset = -4,
          label = { string = menu, width = 0, padding_left = 0, padding_right = 0,
                    color = { alpha = 0.0 } },
        })
      else break end
      id = id + 1
    end
    local count = id - 1
    -- ~0.28s at 60Hz: slide up 4pt while fading in (webpage menus/spaces swap).
    sbar.animate("tanh", 17, function()
      for i = 1, count do park_menu_item(i) end
    end)
  end)
end

menu_watcher:subscribe("front_app_switched", update_menus)

space_menu_swap:subscribe("swap_menus_and_spaces", function(env)
  if menus_shown then
    menus_shown = false
    MENUS_VISIBLE = false
    menu_watcher:set( { updates = false })
    menu_hide_seq = menu_hide_seq + 1
    local seq = menu_hide_seq
    sbar.animate("tanh", 17, function()
      for i = 1, max_items do
        menu_items[i]:set({
          padding_left = 0,
          padding_right = 0,
          y_offset = -4,
          label = { width = 0, padding_left = 0, padding_right = 0,
                    color = { alpha = 0.0 } },
        })
      end
    end)
    sbar.delay(0.28, function()   -- collapse first, then hand back the bar
      if menu_hide_seq ~= seq then return end
      sbar.set("/menu\\..*/", { drawing = false })
      menu_padding:set({ drawing = false })
      for i = 1, max_items do park_menu_item(i) end
      if not YSUITE_LIQUID then sbar.set("front_app", { drawing = true }) end
      -- YBAR PORT: a blanket show resurrects every configured workspace
      -- (6..9, A..Z). Restore through the spaces refresh instead, which only
      -- shows non-empty or focused workspaces and re-applies highlights.
      sbar.exec("aerospace list-workspaces --focused 2>/dev/null", function(focused)
        sbar.trigger("aerospace_workspace_change",
          { FOCUSED_WORKSPACE = focused:gsub("%s+", "") })
      end)
    end)
  else
    menus_shown = true
    MENUS_VISIBLE = true
    menu_hide_seq = menu_hide_seq + 1   -- cancel a pending collapse cleanup
    menu_watcher:set( { updates = true })
    sbar.set("/space\\..*/", { drawing = false })
    -- The active pill is the menu toggle, so it stays while the others hide.
    if ACTIVE_SPACE_NAME then
      sbar.set(ACTIVE_SPACE_NAME, { drawing = true })
      local slot = ACTIVE_SPACE_NAME:match("^space%.(%d+)$")
      if slot then sbar.set("space.padding." .. slot, { drawing = true }) end
    end
    if not YSUITE_LIQUID then sbar.set("front_app", { drawing = false }) end
    update_menus()
  end
end)

return menu_watcher
