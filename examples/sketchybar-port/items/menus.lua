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

-- Per-workspace menu state -------------------------------------------------
-- The bar shows either the workspace pills or the front app's menus, and
-- which one is showing is a property of the WORKSPACE, not of the bar. Opening
-- the menus and switching away hands the pills back — the menus belonged to
-- the app you just left — and switching home brings them back up.
--
-- Keyed on the AeroSpace workspace name, which is the only identifier its
-- event carries. The builtin space_change (native Spaces, the yabai adapter)
-- carries no name at all, so that path gets the hand-back half and no
-- restore: better than today, where a switch left the menus up over pills
-- that had gone stale behind them.
local menu_open_on = {}     -- workspace name -> true while its menus are up
local current_workspace     -- nil until the first workspace event lands
local restore_seq = 0

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

-- `remember` is false when the switch handler drives these: a workspace change
-- records the OUTGOING workspace's state itself, before it reassigns
-- current_workspace, and must not have the close overwrite the incoming one.
-- The active pill is the menu toggle, so it stays while the others hide.
local function show_only_active_pill()
  sbar.set("/space\\..*/", { drawing = false })
  if ACTIVE_SPACE_NAME then
    sbar.set(ACTIVE_SPACE_NAME, { drawing = true })
    local slot = ACTIVE_SPACE_NAME:match("^space%.(%d+)$")
    if slot then sbar.set("space.padding." .. slot, { drawing = true }) end
  end
end

local function close_menus(remember)
  if remember ~= false and current_workspace then
    menu_open_on[current_workspace] = false
  end
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
end

local function open_menus(remember)
  if remember ~= false and current_workspace then
    menu_open_on[current_workspace] = true
  end
  menus_shown = true
  MENUS_VISIBLE = true
  menu_hide_seq = menu_hide_seq + 1   -- cancel a pending collapse cleanup
  menu_watcher:set( { updates = true })
  show_only_active_pill()
  if not YSUITE_LIQUID then sbar.set("front_app", { drawing = false }) end
  update_menus()
end

space_menu_swap:subscribe("swap_menus_and_spaces", function(env)
  if menus_shown then close_menus() else open_menus() end
end)

-- A real workspace switch. The event is registered by whichever spaces
-- adapter loads AFTER this file, so register it here too — addEvent is a
-- no-op for a name that already exists, which is the same thing the yabai
-- adapter relies on.
sbar.add("event", "aerospace_workspace_change")

local function workspace_changed(incoming)
  incoming = (incoming or ""):gsub("%s+", "")
  -- The close path re-triggers this with the workspace we are already on
  -- (that is how it hands the pills back), so only a real move counts.
  if incoming == "" or incoming == current_workspace then return end
  local previous = current_workspace
  if previous then menu_open_on[previous] = menus_shown end
  current_workspace = incoming

  restore_seq = restore_seq + 1
  local seq = restore_seq
  local want = menu_open_on[incoming] == true

  if want and menus_shown then
    -- Both sides want the menus, so they stay up — closing and reopening
    -- would read as a blink for no reason. But the pill showing underneath
    -- them is the menu toggle and it names the front app, and spaces.lua's
    -- own refresh is gated off while the menus are visible, so the refocus
    -- has to be asked for: without it the pill kept the name of the
    -- workspace being left.
    if MENUS_REFOCUS then MENUS_REFOCUS(incoming) end
    show_only_active_pill()
    update_menus()
  elseif want then
    -- The pills repaint on this same event and set ACTIVE_SPACE_NAME, which
    -- the open path needs. Subscriber order between the two files is not
    -- guaranteed, so let that land first.
    sbar.delay(0.12, function()
      if seq ~= restore_seq or menus_shown then return end
      open_menus()
    end)
  elseif menus_shown then
    close_menus(false)
  end
end

space_menu_swap:subscribe("aerospace_workspace_change", function(env)
  workspace_changed(env.FOCUSED_WORKSPACE)
end)

-- Native Spaces carry no workspace name, so this can only do the hand-back
-- half: whatever was open belonged to the Space being left.
-- Seed the workspace before anything can toggle, so a swap made at login —
-- before the first switch fires an event — is remembered against the
-- workspace it actually happened on rather than against nil.
sbar.exec("aerospace list-workspaces --focused 2>/dev/null", function(focused)
  focused = (focused or ""):gsub("%s+", "")
  -- A real switch may have landed first; it wins.
  if focused ~= "" and not current_workspace then current_workspace = focused end
end)

space_menu_swap:subscribe("space_change", function()
  if menus_shown then
    if current_workspace then menu_open_on[current_workspace] = true end
    close_menus(false)
  end
end)

return menu_watcher
