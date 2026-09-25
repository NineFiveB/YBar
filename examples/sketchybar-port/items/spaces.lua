local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")
local shell = require("helpers.shell")

-- AeroSpace integration ------------------------------------------------------
-- AeroSpace uses virtual workspaces (not native macOS Spaces), so this widget
-- talks to the `aerospace` CLI instead of yabai. ~/.aerospace.toml triggers the
-- `aerospace_workspace_change` event below via exec-on-workspace-change.
sbar.add("event", "aerospace_workspace_change")

-- Absolute path: sbar.exec runs with the daemon's own PATH, which lacks
-- /opt/homebrew/bin when launched from Finder or a LaunchAgent.
AEROSPACE = "/opt/homebrew/bin/aerospace"
if not os.execute("test -x " .. AEROSPACE) then
  AEROSPACE = "/usr/local/bin/aerospace"
  if not os.execute("test -x " .. AEROSPACE) then AEROSPACE = "aerospace" end
end

-- Pills are a FIXED slot set created at load and bound to workspace names on
-- every reconcile from an async `list-workspaces --all` — the model the
-- yabai adapter already uses. The previous version discovered the names with
-- one synchronous query at config load and created a pill per name, so a bar
-- that came up before AeroSpace answered had no pills to ever reveal
-- (items/init.lua polled the CLI for up to 30 s to paper over that), and a
-- workspace summoned at runtime by a name no binding referenced never got
-- one. Creation order is bar order within a position, so slots created now
-- keep the strip left of front_app; a set that grew lazily would append
-- pills after every item loaded since.
--
-- Workspaces past MAX_SLOTS get no pill. 36 covers the digit + letter
-- convention AeroSpace configs tend to follow; raise it if yours is larger.
-- ysuite-liquid shows at most seven: the focused workspace, then other
-- occupied ones.
local MAX_SLOTS = YSUITE_LIQUID and 7 or 36
local ICON_HIDE_SECONDS = tonumber(settings.workspace_icon_hide) or 10

local spaces = {}    -- slot -> space item
local brackets = {}  -- slot -> bracket item
local names = {}     -- slot -> bound workspace name (nil = unbound)
local slot_of = {}   -- workspace name -> slot
local last_focused   -- workspace name; declared here so pill clicks close over it

for i = 1, MAX_SLOTS do
  local space = sbar.add("item", "space." .. i, {
    icon = {
      font = { family = settings.font.numbers },
      string = "",
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
    -- No background border: the bracket ring is the pill's only outline.
    -- A second 1pt border at the background edge reads as a detached line
    -- inside the ring (the "double outline" gap).
    background = {
      color = colors.bg1,
      border_width = 0,
      height = 26,
    },
    popup = { background = { border_width = 5, border_color = colors.black } },
    -- Left click focuses the workspace via AeroSpace; the command is set
    -- when a name is bound to the slot (bind_names). Liquid handles the
    -- click itself: the active pill toggles the app menu.
    click_script = YSUITE_LIQUID and "" or nil,
    drawing = false,
  })

  spaces[i] = space

  if YSUITE_LIQUID then
    space:subscribe("mouse.clicked", function()
      local name = names[i]
      if not name then return end
      if name == last_focused then
        sbar.trigger("swap_menus_and_spaces")
      else
        sbar.exec(AEROSPACE .. " workspace " .. shell.quote(name))
      end
    end)
  end

  -- Single item bracket for space items to achieve double border on highlight
  brackets[i] = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      -- 0, not 2: the ring belongs to the focused pill and apply_focus sets
      -- it there. Starting at 0 avoids a one-frame ring on a pill revealed
      -- before focus has been applied to it.
      border_width = 0,
    },
  })

  -- Padding space (visibility tracks the workspace item).
  sbar.add("item", "space.padding." .. i, {
    script = "",
    width = settings.group_paddings,
    drawing = false,
  })
end

-- Pill visibility -------------------------------------------------------------
-- An emptied workspace slides shut (width and paddings animate to zero)
-- before it stops drawing, instead of vanishing between two frames.
-- `shown` tracks which pills are visually present (so only a real
-- shown->hidden transition animates); `hiding` carries a sequence number so
-- a reveal landing mid-collapse cancels the delayed drawing=off cleanly.
-- All three are keyed by SLOT: the binding may move under a slot, and the
-- reconcile that moved it repaints the slot from the visible set.
local shown = {}     -- slot -> pill currently visible
local hiding = {}    -- slot -> hide_seq of the in-flight collapse
local hide_seq = 0
local empty = {}     -- slot -> false once windows are seen (nil = unknown/new)
local icon_lines = {} -- slot -> app-icon string from the last window query
local front_app_name = ""
local icons_settled = false
local icon_timer_seq = 0

-- Bind the ordered workspace list to slots. A slot whose name changes (a
-- workspace summoned or removed above it) forgets what it knew about the
-- old one: the name and the click target follow the binding at once, and
-- the caller's reconcile pass repaints occupancy and visibility. Returns
-- whether any slot changed hands.
-- The glyph is the workspace's own number, not its place in the row, so
-- moving the focused workspace to the front does not renumber the others.
local function workspace_mark(name)
  if not name then return "" end
  if not YSUITE_LIQUID then return name end
  local n = tonumber(name)
  if n then return tostring(n) end
  return name
end

local function bind_names(list)
  slot_of = {}
  local changed = false
  for i = 1, MAX_SLOTS do
    local name = list[i]
    if name then slot_of[name] = i end
    if name ~= names[i] then
      changed = true
      names[i] = name
      empty[i] = nil
      icon_lines[i] = nil
      spaces[i]:set({
        icon = { string = workspace_mark(name), drawing = true },
        click_script = (name and not YSUITE_LIQUID)
          and (AEROSPACE .. " workspace " .. shell.quote(name)) or "",
      })
    end
  end
  if YSUITE_LIQUID then
    local slot = last_focused and slot_of[last_focused]
    ACTIVE_SPACE_NAME = slot and ("space." .. slot) or nil
  end
  return changed
end

local function list_key(list)
  local parts = {}
  for i = 1, #list do parts[i] = tostring(list[i]) end
  return table.concat(parts, "\0")
end

local function lists_equal(a, b)
  if #a ~= #b then return false end
  for i = 1, #a do
    if a[i] ~= b[i] then return false end
  end
  return true
end

-- Focused workspace first, then other occupied workspaces in WM order.
local function promoted_order(all, visible, focused)
  local list = {}
  if focused and focused ~= "" then list[1] = focused end
  for _, name in ipairs(all) do
    if #list >= MAX_SLOTS then break end
    if name ~= focused and visible[name] then list[#list + 1] = name end
  end
  return list
end

-- Same pills, but leave the focused workspace where it already sits.
local function stable_order(all, visible, focused)
  local list, seen = {}, {}
  local function take(name)
    if not name or seen[name] or #list >= MAX_SLOTS then return end
    if name == focused or visible[name] then
      list[#list + 1] = name
      seen[name] = true
    end
  end
  for i = 1, MAX_SLOTS do take(names[i]) end
  for _, name in ipairs(all) do take(name) end
  return list
end

local rearrange_seq = 0
local pending_order_key = ""
local reordering = false
local liquid_ordered_once = false
local REARRANGE_DELAY = 1.3
local name_transition_seq = 0
local name_transition_slot = nil
local paint_liquid, update_windows, apply_focus

local function pill_frame(slot)
  local info = spaces[slot]:query()
  if type(info) ~= "table" or type(info.bounding_rects) ~= "table" then
    return nil, nil
  end
  for _, rect in pairs(info.bounding_rects) do
    if type(rect) == "table" and type(rect.origin) == "table" and type(rect.size) == "table" then
      local x, w = rect.origin[1], rect.size[1]
      if type(x) == "number" and type(w) == "number" then return x, w end
    end
  end
  return nil, nil
end

local function hide_outlines()
  for slot = 1, MAX_SLOTS do
    brackets[slot]:set({ background = { border_width = 0 } })
  end
end

local function finish_rearrange(focused, seq)
  reordering = false
  for slot = 1, MAX_SLOTS do
    if names[slot] then
      spaces[slot]:set({ x_offset = 0, y_offset = 0 })
    end
  end
  if seq == rearrange_seq then
    pending_order_key = ""
    if focused and focused ~= "" then apply_focus(focused) end
  end
  for slot = 1, MAX_SLOTS do
    if names[slot] and shown[slot] then paint_liquid(slot) end
  end
end

-- Slide each workspace from where it sits to its new slot. The outline is
-- hidden for the slide: it follows the pill's box, but the glass view and
-- the ring disagree for a frame while widths change underneath the motion.
local function animate_rearrange(list, focused, seq)
  reordering = true
  local x_of, width_of = {}, {}
  local start_x, gap, prev_x, prev_w
  for slot = 1, MAX_SLOTS do
    local name = names[slot]
    if name and shown[slot] then
      local x, w = pill_frame(slot)
      if x and w then
        x_of[name] = x
        width_of[name] = w
        if not start_x or x < start_x then start_x = x end
        if prev_x and prev_w and not gap then gap = x - (prev_x + prev_w) end
        prev_x, prev_w = x, w
      end
    end
  end
  gap = gap or 0

  local kept_icons, kept_empty = {}, {}
  for slot = 1, MAX_SLOTS do
    local name = names[slot]
    if name then
      kept_icons[name] = icon_lines[slot]
      kept_empty[name] = empty[slot]
    end
  end

  if seq ~= rearrange_seq then
    finish_rearrange(focused, seq)
    return
  end

  bind_names(list)
  hide_outlines()
  local cursor = start_x
  for slot = 1, MAX_SLOTS do
    local name = names[slot]
    if name then
      icon_lines[slot] = kept_icons[name]
      if kept_empty[name] ~= nil then empty[slot] = kept_empty[name] end
      shown[slot] = true
      hiding[slot] = nil
      local dx = 0
      local width = width_of[name] or 36
      if cursor and x_of[name] then dx = x_of[name] - cursor end
      if cursor then cursor = cursor + width + gap end
      spaces[slot]:set({
        drawing = true,
        x_offset = dx,
        y_offset = 0,
      })
      sbar.set("space.padding." .. slot, {
        drawing = true,
        width = settings.group_paddings,
        padding_left = 5,
        padding_right = 5,
      })
      paint_liquid(slot)
    elseif shown[slot] then
      shown[slot] = nil
      spaces[slot]:set({ drawing = false, x_offset = 0, y_offset = 0 })
      sbar.set("space.padding." .. slot, { drawing = false })
    end
  end
  -- paint_liquid puts the ring back; the slide keeps it off.
  hide_outlines()
  sbar.animate("tanh", 16, function()
    for slot = 1, MAX_SLOTS do
      if names[slot] then spaces[slot]:set({ x_offset = 0 }) end
    end
  end)
  sbar.delay(0.28, function()
    finish_rearrange(focused, seq)
    for slot = 1, MAX_SLOTS do
      if names[slot] then update_windows(slot) end
    end
  end)
end

local function schedule_rearrange(list, focused)
  local key = list_key(list)
  if key == pending_order_key then return end
  pending_order_key = key
  rearrange_seq = rearrange_seq + 1
  local seq = rearrange_seq
  sbar.delay(REARRANGE_DELAY, function()
    if seq ~= rearrange_seq then return end
    if MENUS_VISIBLE then
      pending_order_key = ""
      return
    end
    animate_rearrange(list, focused, seq)
  end)
end

-- The bracket ring only outlines workspaces that actually hold windows; an
-- empty/new workspace shows as a bare pill.
-- Only the focused pill wears the ring. It sits 1pt outside the pill's own
-- lit edge, so on the focused pill it reads as a second capsule and gives the
-- selection depth; on every other pill it is just an outline around the glass.
local function bracket_border(slot)
  return (last_focused and slot_of[last_focused] == slot) and 2 or 0
end

local function sync_active_item()
  local slot = last_focused and slot_of[last_focused]
  ACTIVE_SPACE_NAME = slot and ("space." .. slot) or nil
end

-- Preview: number + app icons. After the hide timer, other pills keep the
-- number and the active pill shows the front app name.
function paint_liquid(slot)
  if slot == name_transition_slot then return end
  local name = names[slot]
  local space = spaces[slot]
  if not name or not space or hiding[slot] then return end
  local active = name == last_focused
  local icons = icon_lines[slot] or ""
  local has_icons = icons ~= ""
  if icons_settled and active then
    space:set({
      icon = { drawing = false, string = "" },
      label = {
        drawing = true,
        string = front_app_name ~= "" and front_app_name or workspace_mark(name),
        font = {
          family = settings.font.text,
          style = settings.font.style_map["Regular"],
          size = 13.0,
        },
        padding_left = 12,
        padding_right = 12,
        color = colors.white,
        -- The shared label offset is tuned for app-icon glyphs, which leaves
        -- the name sitting low in the pill.
        y_offset = 1,
      },
    })
  elseif icons_settled or not has_icons then
    space:set({
      icon = {
        drawing = true,
        string = workspace_mark(name),
        font = { family = settings.font.numbers },
        padding_left = 12,
        padding_right = 12,
      },
      label = { drawing = false, string = "" },
    })
  else
    space:set({
      icon = {
        drawing = true,
        string = workspace_mark(name),
        font = { family = settings.font.numbers },
        padding_left = 8,
        padding_right = 4,
      },
      label = {
        drawing = true,
        string = icons,
        font = "sketchybar-app-font:Regular:16.0",
        padding_right = 8,
        padding_left = 4,
        color = active and colors.white or colors.grey,
        y_offset = -1,
      },
    })
  end
  brackets[slot]:set({ background = { border_width = bracket_border(slot) } })
end

-- Focused pill: the number and app icons leave first, then the front app
-- name arrives. The ring stays off until the name has settled, so it cannot
-- sit on the old width while the label changes.
local function begin_name_transition(slot)
  if reordering then return end
  local space = spaces[slot]
  if not space or names[slot] ~= last_focused then return end
  name_transition_seq = name_transition_seq + 1
  local seq = name_transition_seq
  name_transition_slot = slot
  brackets[slot]:set({ background = { border_width = 0 } })
  sbar.animate("tanh", 9, function()
    space:set({
      icon = { color = { alpha = 0.0 }, padding_left = 2, padding_right = 0 },
      label = { color = { alpha = 0.0 }, padding_left = 0, padding_right = 2 },
    })
  end)
  sbar.delay(0.17, function()
    if seq ~= name_transition_seq or names[slot] ~= last_focused or not icons_settled then
      if name_transition_slot == slot then name_transition_slot = nil end
      paint_liquid(slot)
      return
    end
    local title = front_app_name ~= "" and front_app_name or workspace_mark(names[slot])
    space:set({
      icon = { drawing = false, string = "", color = { alpha = 0.0 } },
      label = {
        drawing = true,
        string = title,
        font = {
          family = settings.font.text,
          style = settings.font.style_map["Regular"],
          size = 13.0,
        },
        padding_left = 2,
        padding_right = 2,
        color = { alpha = 0.0 },
        y_offset = 1,
      },
    })
    sbar.animate("tanh", 11, function()
      space:set({
        label = {
          padding_left = 12,
          padding_right = 12,
          color = { alpha = 1.0 },
        },
      })
    end)
    sbar.delay(0.20, function()
      if name_transition_slot == slot then name_transition_slot = nil end
      if seq ~= name_transition_seq then return end
      paint_liquid(slot)
    end)
  end)
end

local function arm_icon_timer()
  if not YSUITE_LIQUID then return end
  name_transition_seq = name_transition_seq + 1
  name_transition_slot = nil
  icons_settled = false
  icon_timer_seq = icon_timer_seq + 1
  local seq = icon_timer_seq
  for slot = 1, MAX_SLOTS do
    if names[slot] and shown[slot] and not hiding[slot] then paint_liquid(slot) end
  end
  sbar.delay(ICON_HIDE_SECONDS, function()
    if seq ~= icon_timer_seq then return end
    icons_settled = true
    for slot = 1, MAX_SLOTS do
      if names[slot] and shown[slot] and not hiding[slot] then
        if names[slot] == last_focused then
          begin_name_transition(slot)
        else
          paint_liquid(slot)
        end
      end
    end
  end)
end

-- Fetch the app icons for a workspace and render them as the space label.
function update_windows(slot)
  local name = names[slot]
  if not name then return end
  sbar.exec(
    AEROSPACE .. " list-windows --workspace " .. shell.quote(name)
      .. " --format '%{app-name}' 2>/dev/null",
    function(windows)
      -- The slot may have been rebound while the query was in flight.
      if names[slot] ~= name then return end
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

      local space = spaces[slot]
      empty[slot] = (icon_line == "")
      icon_lines[slot] = icon_line
      -- A collapsing pill is animating these exact properties; direct sets
      -- would cancel the animations and snap it back open mid-slide.
      if hiding[slot] then return end
      if YSUITE_LIQUID then
        paint_liquid(slot)
        return
      end
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
      brackets[slot]:set({ background = { border_width = bracket_border(slot) } })
    end
  )
end

-- Undo the collapse geometry. Direct sets cancel any in-flight animation on
-- the same properties, so this doubles as the mid-collapse abort.
local function restore_pill(slot)
  -- Park the geometry the pill will actually reveal with: an empty pill is
  -- 12/12 with no label; parking the non-empty 8/4 look makes the reveal
  -- pop wider ~200ms later when update_windows lands.
  local is_empty = empty[slot] ~= false
  spaces[slot]:set({
    padding_left = 1,
    padding_right = 1,
    y_offset = 0,
    icon = {
      width = "dynamic",
      padding_left = is_empty and 12 or 8,
      padding_right = is_empty and 12 or 4,
      color = { alpha = 1.0 },
    },
    label = {
      width = "dynamic", padding_left = 4, padding_right = 8,
      drawing = not is_empty, color = { alpha = 1.0 },
    },
  })
  brackets[slot]:set({ background = { border_width = bracket_border(slot) } })
  sbar.set("space.padding." .. slot,
    { width = settings.group_paddings, padding_left = 5, padding_right = 5 })
end

-- drawing=on is set unconditionally: menus.lua hides pills behind our back
-- with a regex set, so `shown` can be stale when the menus swap away.
local function reveal_pill(slot)
  local was_hidden = not shown[slot]
  if hiding[slot] then
    hiding[slot] = nil
    restore_pill(slot)
    was_hidden = true
  elseif not shown[slot] and empty[slot] ~= false then
    -- Believed-empty pill about to appear: paint the empty geometry NOW so
    -- it shows up at final size — update_windows only confirms it later
    -- (items are created 8/4, so the first-ever reveal pops without this).
    spaces[slot]:set({
      label = { drawing = false },
      icon = { padding_left = 12, padding_right = 12 },
    })
  end
  shown[slot] = true
  if was_hidden then
    spaces[slot]:set({
      drawing = true,
      y_offset = 4,
      icon = { color = { alpha = 0.0 } },
      label = { color = { alpha = 0.0 } },
    })
    sbar.set("space.padding." .. slot, { drawing = true })
    sbar.animate("tanh", 13, function()
      spaces[slot]:set({
        y_offset = 0,
        icon = { color = { alpha = 1.0 } },
        label = { color = { alpha = 1.0 } },
      })
    end)
  else
    spaces[slot]:set({ drawing = true })
    sbar.set("space.padding." .. slot, { drawing = true })
  end
end

local function collapse_pill(slot)
  hide_seq = hide_seq + 1
  local seq = hide_seq
  hiding[slot] = seq
  sbar.animate("tanh", 13, function()
    spaces[slot]:set({
      padding_left = 0,
      padding_right = 0,
      y_offset = -4,
      icon = { width = 0, padding_left = 0, padding_right = 0, color = { alpha = 0.0 } },
      label = { width = 0, padding_left = 0, padding_right = 0, color = { alpha = 0.0 } },
    })
    brackets[slot]:set({ background = { border_width = 0 } })
    -- The spacer's full footprint is width + its default 5/5 item paddings;
    -- leaving the paddings un-animated would snap 10pt shut at cleanup.
    sbar.set("space.padding." .. slot, { width = 0, padding_left = 0, padding_right = 0 })
  end)
  sbar.delay(0.22, function()   -- 13 frames at 60Hz
    if hiding[slot] ~= seq then return end
    hiding[slot] = nil
    shown[slot] = nil
    spaces[slot]:set({ drawing = false })
    sbar.set("space.padding." .. slot, { drawing = false })
    restore_pill(slot)          -- park clean geometry for the next reveal
  end)
end

-- Refresh which workspaces are visible/highlighted. Visible = non-empty OR the
-- focused workspace; highlighted = focused.
-- Instant phase: the event already names the focused workspace — the
-- cross-fade and the focused pill's reveal must not wait for the
-- aerospace query round-trip. A name with no slot yet (a workspace seen for
-- the first time) waits for the reconcile that binds it.
function apply_focus(focused)
  -- Instant, no animation: switching must feel immediate.
  for slot, space in pairs(spaces) do
    if names[slot] then
      local selected = (names[slot] == focused)
      space:set({
        icon = { color = colors.white },
        label = { color = selected and colors.white or colors.grey },
        background = {
          color = selected and colors.with_alpha(colors.grey, 0.5) or colors.bg1,
          -- The selection is a plain highlight: its fill is opaque enough to
          -- hide the material anyway, and lighting a half-opaque plate reads
          -- as paint. Both off together — with glass off the painted pass
          -- would fall back to modelling a body, bottom shade included.
          glass = not selected,
          sheen = not selected,
        },
      })
      brackets[slot]:set({
        background = {
          border_color = selected and colors.grey or colors.bg2,
          border_width = selected and 2 or 0,
        },
      })
    end
  end

  local slot = slot_of[focused]
  if slot then reveal_pill(slot) end
  if YSUITE_LIQUID then sync_active_item() end

  -- The workspace being left collapses NOW if it holds no windows — waiting
  -- for the debounce + aerospace round-trip reads as lag. empty[slot] == nil
  -- (new, never-inspected workspace) counts as empty; the reconcile pass
  -- corrects the rare miss.
  local last_slot = last_focused and slot_of[last_focused]
  if last_slot and last_focused ~= focused
      and empty[last_slot] ~= false
      and shown[last_slot] and not hiding[last_slot] then
    collapse_pill(last_slot)
  end
  last_focused = focused
end

-- Reconcile generation: rapid switching debounces into one query burst,
-- and late callbacks from superseded switches are dropped instead of
-- repainting stale state out of order.
local reconcile_gen = 0
local reconcile
local MAX_RETRIES = 5

-- One child shell, two CLI calls: the full workspace list (slot binding)
-- and the non-empty list (visibility). An empty line separates them — a
-- workspace name is never empty, so the split is unambiguous.
-- YBAR PORT: right after wake (or login) the AeroSpace server can take a few
-- seconds to answer, and an empty reply means "not ready", not "no
-- workspaces" — hiding every space on it would blank the bar until the next
-- manual switch. Retry a few times instead.
reconcile = function(focused, attempt, gen)
  sbar.exec(
    AEROSPACE .. " list-workspaces --all 2>/dev/null; echo; "
      .. AEROSPACE .. " list-workspaces --monitor all --empty no 2>/dev/null",
    function(out)
      if gen ~= reconcile_gen then return end
      -- The menus may have swapped in while this query was in flight; a
      -- reveal now would draw pills over the open app menus, and nothing
      -- hides them again until the next swap.
      if MENUS_VISIBLE or reordering then return end
      local all, visible, past_break = {}, {}, false
      for line in (out .. "\n"):gmatch("([^\n]*)\n") do
        local ws = line:match("^%s*(.-)%s*$")
        if ws == "" then
          past_break = true
        elseif past_break then
          visible[ws] = true
        else
          all[#all + 1] = ws
        end
      end
      if #all == 0 and (attempt or 0) < MAX_RETRIES then
        sbar.exec("sleep 2", function()
          if gen == reconcile_gen then reconcile(focused, (attempt or 0) + 1, gen) end
        end)
        return
      end
      -- Retries exhausted on an empty list: AeroSpace is gone. Binding the
      -- empty list unbinds every slot and the loop below collapses them,
      -- exactly as the old "no workspaces" path did; the routine poll
      -- rebinds the moment it answers again.
      if focused and focused ~= "" then visible[focused] = true end
      -- Liquid keeps the current order for 2.5s, then eases the focused
      -- workspace to the front. Membership (who is on the bar) updates now.
      local list = all
      if YSUITE_LIQUID then
        local promoted = promoted_order(all, visible, focused)
        if not liquid_ordered_once then
          list = promoted
          liquid_ordered_once = true
          pending_order_key = ""
        else
          list = stable_order(all, visible, focused)
          if lists_equal(list, promoted) then
            rearrange_seq = rearrange_seq + 1
            pending_order_key = ""
          else
            schedule_rearrange(promoted, focused)
          end
        end
      end
      local rebound = bind_names(list)
      if focused and focused ~= "" then
        -- The instant focus paint went by name; when names just moved under
        -- the slots (first paint, a summoned or removed workspace) it landed
        -- on nothing or on the wrong pill, so paint again from the binding.
        if rebound then apply_focus(focused) end
      end

      for slot = 1, MAX_SLOTS do
        local name = names[slot]
        local show = name and (YSUITE_LIQUID or visible[name])
        if show then
          reveal_pill(slot)
          update_windows(slot)
        elseif shown[slot] and not hiding[slot] then
          collapse_pill(slot)
        end
      end
    end)
end

local function update_spaces(focused, attempt, reset_icons)
  if reset_icons then arm_icon_timer() end
  if focused and focused ~= "" then
    apply_focus(focused)          -- instant, per switch
  end
  reconcile_gen = reconcile_gen + 1
  local gen = reconcile_gen
  sbar.delay(0.12, function()     -- debounce: one reconcile after a burst
    if gen == reconcile_gen then reconcile(focused, attempt or 0, gen) end
  end)
end

local space_observer = sbar.add("item", {
  drawing = false,
  updates = true,
  update_freq = 5,
})

-- AeroSpace passes FOCUSED_WORKSPACE through the triggered event.
-- MENUS_VISIBLE (set by menus.lua) guards every refresh path so a resync
-- can't resurrect the workspace pills while the app menus are shown.
space_observer:subscribe("aerospace_workspace_change", function(env)
  if MENUS_VISIBLE then return end
  local focused = env.FOCUSED_WORKSPACE
  -- Menu close re-triggers this with the same workspace. Only a real
  -- switch restarts the icon timer.
  update_spaces(focused, 0, focused ~= last_focused and focused ~= "")
end)

-- Query the focused workspace and repaint — used for the initial paint and
-- the post-wake resync, with retries while AeroSpace is still starting up.
-- The retry budget is shared with the reconcile that follows.
local function query_and_update(attempt, reset_icons)
  sbar.exec(AEROSPACE .. " list-workspaces --focused 2>/dev/null", function(focused)
    focused = focused:gsub("%s+", "")
    if focused == "" and (attempt or 0) < MAX_RETRIES then
      sbar.exec("sleep 2", function() query_and_update((attempt or 0) + 1, reset_icons) end)
      return
    end
    if MENUS_VISIBLE then return end
    update_spaces(focused, attempt, reset_icons)
  end)
end

-- YBAR PORT: AeroSpace only fires exec-on-workspace-change on real switches,
-- so nothing repaints after sleep and the pills stay stale or hidden —
-- resync on the daemon's system_woke event.
space_observer:subscribe("system_woke", function() query_and_update() end)

-- YBAR PORT: apps opening and closing repaint the pills immediately —
-- front_app_switched fires both when a launched app takes focus and when
-- a quit app hands focus back, so icons don't wait for the next switch.
space_observer:subscribe("front_app_switched", function(env)
  if env.INFO and env.INFO ~= "" then front_app_name = env.INFO end
  query_and_update(nil, true)
end)

-- app_launched/app_terminated (ybar events) catch what focus changes miss:
-- background apps quitting, agents launching without taking focus.
space_observer:subscribe({ "app_launched", "app_terminated" }, function()
  query_and_update(nil, true)
end)

-- Minimize/window-close emit no OS-level event at all — a light routine
-- poll reconciles those within seconds. It is also what brings the strip
-- up when AeroSpace starts long after the bar (or is not installed), so it
-- runs with the retry budget spent: the next tick IS the retry, and a
-- fresh 2 s sleep chain every 5 s would pile up on a machine with no WM.
space_observer:subscribe("routine", function() query_and_update(MAX_RETRIES) end)

-- Initial paint at config load. Icons show, then hide after the delay.
query_and_update(nil, true)

if not YSUITE_LIQUID then
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

-- YBAR PORT: only when there is a swap to reflect. Without the opt-in menus
-- helper items/menus.lua registers no handler for this event, so the pills
-- stay put — flipping the glyph to "off" would advertise a state the bar is
-- not in (items/init.lua requires items.menus first, so the flag is set).
if MENUS_HELPER_AVAILABLE then
  spaces_indicator:subscribe("swap_menus_and_spaces", function(env)
    local currently_on = spaces_indicator:query().icon.value == icons.switch.on
    spaces_indicator:set({
      icon = currently_on and icons.switch.off or icons.switch.on
    })
  end)
end

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
end
