local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local app_icons = require("helpers.app_icons")

-- yabai integration -----------------------------------------------------------
-- yabai manages native macOS Spaces, so the engine's builtin space_change event
-- (NSWorkspace.activeSpaceDidChange) fires on every switch — no exec-on-change
-- hook to configure. The event carries no space index, so every refresh
-- re-queries yabai. All queries fail soft: yabai not installed / not answering
-- means empty output, retries, and hidden pills — never a load error.
local yabai = "/opt/homebrew/bin/yabai"
if not os.execute("test -x " .. yabai) then
  yabai = "/usr/local/bin/yabai"
end

-- menus.lua restores the pills after a swap by triggering
-- aerospace_workspace_change; register it here too so that path resyncs the
-- yabai pills instead of dying on an unknown event.
sbar.add("event", "aerospace_workspace_change")

-- yabai signals (see examples/yabai-skhd/yabairc): window create/destroy/
-- minimize emit no OS-level event at all, so without signals those changes
-- wait for the 5s routine poll. The CLI folds every $YABAI_* signal variable
-- into the trigger env automatically.
sbar.add("event", "yabai_space_change")
sbar.add("event", "yabai_window_change")

-- Native Spaces are numbered 1..N in Mission Control order and can be created
-- and destroyed at runtime — and yabai may not be answering at config load —
-- so a fixed set of pills is created up front and reconcile hides the indices
-- that don't currently exist.
local MAX_SPACES = YSUITE_LIQUID and 7 or 10
local ICON_HIDE_SECONDS = tonumber(settings.workspace_icon_hide) or 10

local spaces = {}    -- sid -> space item
local brackets = {}  -- sid -> bracket item
-- Liquid slots are visual positions. names[slot] is the real space index
-- so the focused space can sit first without renumbering the others.
local names = {}
local last_focused

for sid = 1, MAX_SPACES do
  local space = sbar.add("item", "space." .. sid, {
    icon = {
      font = { family = settings.font.numbers },
      string = YSUITE_LIQUID and "" or sid,
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
    background = {
      color = colors.bg1,
      border_width = 0,
      height = 26,
    },
    popup = { background = { border_width = 5, border_color = colors.black } },
    -- Left click focuses the space (needs yabai's scripting addition on
    -- recent macOS; without it the click is a silent no-op).
    click_script = YSUITE_LIQUID and "" or (yabai .. " -m space --focus " .. sid),
    drawing = false,
  })

  spaces[sid] = space

  if YSUITE_LIQUID then
    space:subscribe("mouse.clicked", function()
      local index = names[sid]
      if not index then return end
      if index == last_focused then
        sbar.trigger("swap_menus_and_spaces")
      else
        sbar.exec(yabai .. " -m space --focus " .. index)
      end
    end)
  end

  -- Single item bracket for space items to achieve double border on highlight
  brackets[sid] = sbar.add("bracket", { space.name }, {
    background = {
      color = colors.transparent,
      border_color = colors.bg2,
      height = 28,
      -- 0, not 2: bracket_border() sets 2 the moment a space is confirmed
      -- non-empty, but a space that hasn't appeared in a query yet (a
      -- brand-new workspace) never runs that path before its first reveal —
      -- defaulting to "no ring" avoids a one-frame flash on that reveal.
      border_width = 0,
    },
  })

  -- Padding space (visibility tracks the space item).
  sbar.add("item", "space.padding." .. sid, {
    script = "",
    width = settings.group_paddings,
    drawing = false,
  })
end

-- Pill visibility -------------------------------------------------------------
-- An emptied space slides shut (width and paddings animate to zero)
-- before it stops drawing, instead of vanishing between two frames.
-- `shown` tracks which pills are visually present (so only a real
-- shown->hidden transition animates); `hiding` carries a sequence number so
-- a reveal landing mid-collapse cancels the delayed drawing=off cleanly.
local shown = {}     -- sid -> pill currently visible
local hiding = {}    -- sid -> hide_seq of the in-flight collapse
local hide_seq = 0
local empty = {}     -- sid -> false once windows are seen (nil = unknown/new)
local icon_lines = {}
local front_app_name = ""
local icons_settled = false
local icon_timer_seq = 0

local function workspace_mark(index)
  if not index then return "" end
  return tostring(index)
end

local function real_index(slot)
  if YSUITE_LIQUID then return names[slot] end
  return slot
end

-- The bracket ring only outlines spaces that actually hold windows; an
-- empty/new space shows as a bare pill.
local function bracket_border(sid)
  return (empty[sid] == false) and 2 or 0
end

local reordering = false
local name_transition_seq = 0
local name_transition_slot = nil

local function paint_liquid(slot)
  if slot == name_transition_slot then return end
  local index = names[slot]
  local space = spaces[slot]
  if not index or not space or hiding[slot] then return end
  local active = index == last_focused
  local icons = icon_lines[slot] or ""
  if icons_settled and active then
    space:set({
      icon = { drawing = false, string = "" },
      label = {
        drawing = true,
        string = front_app_name ~= "" and front_app_name or workspace_mark(index),
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
  elseif icons_settled or icons == "" then
    space:set({
      icon = {
        drawing = true,
        string = workspace_mark(index),
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
        string = workspace_mark(index),
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

local function begin_name_transition(slot)
  if reordering then return end
  local space = spaces[slot]
  local index = names[slot]
  if not space or index ~= last_focused then return end
  name_transition_seq = name_transition_seq + 1
  local seq = name_transition_seq
  name_transition_slot = slot
  brackets[slot]:set({ background = { border_width = 0 } })
  sbar.animate("tanh", 12, function()
    space:set({
      icon = { color = { alpha = 0.0 }, padding_left = 2, padding_right = 0 },
      label = { color = { alpha = 0.0 }, padding_left = 0, padding_right = 2 },
    })
  end)
  sbar.delay(0.22, function()
    if seq ~= name_transition_seq or names[slot] ~= last_focused or not icons_settled then
      if name_transition_slot == slot then name_transition_slot = nil end
      paint_liquid(slot)
      return
    end
    local title = front_app_name ~= "" and front_app_name or workspace_mark(index)
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
    sbar.animate("tanh", 14, function()
      space:set({
        label = {
          padding_left = 12,
          padding_right = 12,
          color = { alpha = 1.0 },
        },
      })
    end)
    sbar.delay(0.25, function()
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
  for slot = 1, MAX_SPACES do
    if names[slot] and shown[slot] and not hiding[slot] then paint_liquid(slot) end
  end
  sbar.delay(ICON_HIDE_SECONDS, function()
    if seq ~= icon_timer_seq then return end
    icons_settled = true
    for slot = 1, MAX_SPACES do
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

-- Fetch the app icons for a space and render them as the space label.
local function update_windows(sid)
  local index = real_index(sid)
  if not index then return end
  sbar.exec(
    yabai .. " -m query --windows --space " .. index .. " 2>/dev/null",
    function(windows)
      local icon_line = ""
      local seen = {}
      for app in windows:gmatch('"app"%s*:%s*"([^"]*)"') do
        if app ~= "" and not seen[app] then
          seen[app] = true
          local lookup = app_icons[app]
          local icon = ((lookup == nil) and app_icons["Default"] or lookup)
          icon_line = icon_line .. icon .. " "
        end
      end

      local space = spaces[sid]
      if not space then return end
      empty[sid] = (icon_line == "")
      icon_lines[sid] = icon_line
      -- A collapsing pill is animating these exact properties; direct sets
      -- would cancel the animations and snap it back open mid-slide.
      if hiding[sid] then return end
      if YSUITE_LIQUID then
        paint_liquid(sid)
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
      brackets[sid]:set({ background = { border_width = bracket_border(sid) } })
    end
  )
end

-- Undo the collapse geometry. Direct sets cancel any in-flight animation on
-- the same properties, so this doubles as the mid-collapse abort.
local function restore_pill(sid)
  -- Park the geometry the pill will actually reveal with: an empty pill is
  -- 12/12 with no label; parking the non-empty 8/4 look makes the reveal
  -- pop wider ~200ms later when update_windows lands.
  local is_empty = empty[sid] ~= false
  spaces[sid]:set({
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
  brackets[sid]:set({ background = { border_width = bracket_border(sid) } })
  sbar.set("space.padding." .. sid,
    { width = settings.group_paddings, padding_left = 5, padding_right = 5 })
end

-- drawing=on is set unconditionally: menus.lua hides pills behind our back
-- with a regex set, so `shown` can be stale when the menus swap away.
local function reveal_pill(sid)
  local was_hidden = not shown[sid]
  if hiding[sid] then
    hiding[sid] = nil
    restore_pill(sid)
    was_hidden = true
  elseif not shown[sid] and empty[sid] ~= false then
    -- Believed-empty pill about to appear: paint the empty geometry NOW so
    -- it shows up at final size — update_windows only confirms it later
    -- (items are created 8/4, so the first-ever reveal pops without this).
    spaces[sid]:set({
      label = { drawing = false },
      icon = { padding_left = 12, padding_right = 12 },
    })
  end
  shown[sid] = true
  if was_hidden then
    spaces[sid]:set({
      drawing = true,
      y_offset = 4,
      icon = { color = { alpha = 0.0 } },
      label = { color = { alpha = 0.0 } },
    })
    sbar.set("space.padding." .. sid, { drawing = true })
    sbar.animate("tanh", 17, function()
      spaces[sid]:set({
        y_offset = 0,
        icon = { color = { alpha = 1.0 } },
        label = { color = { alpha = 1.0 } },
      })
    end)
  else
    spaces[sid]:set({ drawing = true })
    sbar.set("space.padding." .. sid, { drawing = true })
  end
end

local function collapse_pill(sid)
  hide_seq = hide_seq + 1
  local seq = hide_seq
  hiding[sid] = seq
  sbar.animate("tanh", 17, function()
    spaces[sid]:set({
      padding_left = 0,
      padding_right = 0,
      y_offset = -4,
      icon = { width = 0, padding_left = 0, padding_right = 0, color = { alpha = 0.0 } },
      label = { width = 0, padding_left = 0, padding_right = 0, color = { alpha = 0.0 } },
    })
    brackets[sid]:set({ background = { border_width = 0 } })
    -- The spacer's full footprint is width + its default 5/5 item paddings;
    -- leaving the paddings un-animated would snap 10pt shut at cleanup.
    sbar.set("space.padding." .. sid, { width = 0, padding_left = 0, padding_right = 0 })
  end)
  sbar.delay(0.28, function()   -- 17 frames at 60Hz
    if hiding[sid] ~= seq then return end
    hiding[sid] = nil
    shown[sid] = nil
    spaces[sid]:set({ drawing = false })
    sbar.set("space.padding." .. sid, { drawing = false })
    restore_pill(sid)          -- park clean geometry for the next reveal
  end)
end

-- Refresh which spaces are visible/highlighted. Visible = non-empty OR the
-- focused space; highlighted = focused.
-- Instant phase: the focused index is already known from the cheap
-- --spaces --space query — the cross-fade and the focused pill's reveal
-- must not wait for the full reconcile round-trip.
local function apply_focus(focused)
  -- Instant, no animation: switching must feel immediate.
  for sid, space in pairs(spaces) do
    local selected = (YSUITE_LIQUID and names[sid] == focused) or (not YSUITE_LIQUID and sid == focused)
    space:set({
      icon = { color = colors.white },
      label = { color = selected and colors.white or colors.grey },
      background = {
        color = selected and colors.with_alpha(colors.grey, 0.5) or colors.bg1,
      },
    })
    brackets[sid]:set({
      background = { border_color = selected and colors.grey or colors.bg2 },
    })
  end

  if YSUITE_LIQUID then
    for sid, index in pairs(names) do
      if index == focused then reveal_pill(sid) end
    end
    local active_slot
    for sid, index in pairs(names) do
      if index == focused then active_slot = sid end
    end
    ACTIVE_SPACE_NAME = active_slot and ("space." .. active_slot) or nil
  elseif spaces[focused] then
    reveal_pill(focused)
  end

  -- The space being left collapses NOW if it holds no windows — waiting
  -- for the debounce + yabai round-trip reads as lag. empty[sid] == nil
  -- (never-inspected space) counts as empty; the reconcile pass corrects
  -- the rare miss.
  if not YSUITE_LIQUID and last_focused and last_focused ~= focused and spaces[last_focused]
      and empty[last_focused] ~= false
      and shown[last_focused] and not hiding[last_focused] then
    collapse_pill(last_focused)
  end
  last_focused = focused
end

local rearrange_seq = 0
local pending_order_key = ""
local liquid_ordered_once = false
local REARRANGE_DELAY = 1.3

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

local function promoted_order(visible, focused)
  local ordered = {}
  if focused then ordered[1] = focused end
  local indices = {}
  for sid in pairs(visible) do indices[#indices + 1] = sid end
  table.sort(indices)
  for _, sid in ipairs(indices) do
    if #ordered >= MAX_SPACES then break end
    if sid ~= focused then ordered[#ordered + 1] = sid end
  end
  return ordered
end

local function stable_order(visible, focused)
  local list, seen = {}, {}
  local function take(index)
    if not index or seen[index] or #list >= MAX_SPACES then return end
    if index == focused or visible[index] then
      list[#list + 1] = index
      seen[index] = true
    end
  end
  for slot = 1, MAX_SPACES do take(names[slot]) end
  local indices = {}
  for sid in pairs(visible) do indices[#indices + 1] = sid end
  table.sort(indices)
  for _, sid in ipairs(indices) do take(sid) end
  return list
end

local function bind_order(ordered)
  for slot = 1, MAX_SPACES do
    local index = ordered[slot]
    if index ~= names[slot] then
      names[slot] = index
      icon_lines[slot] = nil
      empty[slot] = nil
      spaces[slot]:set({
        icon = { string = index and workspace_mark(index) or "", drawing = index ~= nil },
      })
    end
  end
  local focused_slot
  for slot = 1, MAX_SPACES do
    if names[slot] == last_focused then focused_slot = slot end
  end
  ACTIVE_SPACE_NAME = focused_slot and ("space." .. focused_slot) or nil
end

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
  for slot = 1, MAX_SPACES do
    brackets[slot]:set({ background = { border_width = 0 } })
  end
end

local function finish_rearrange(focused, seq)
  reordering = false
  for slot = 1, MAX_SPACES do
    if names[slot] then spaces[slot]:set({ x_offset = 0, y_offset = 0 }) end
  end
  if seq == rearrange_seq then
    pending_order_key = ""
    if focused then apply_focus(focused) end
  end
  for slot = 1, MAX_SPACES do
    if names[slot] and shown[slot] then paint_liquid(slot) end
  end
end

local function animate_rearrange(ordered, focused, seq)
  reordering = true
  local x_of, width_of = {}, {}
  local start_x, gap, prev_x, prev_w
  for slot = 1, MAX_SPACES do
    local index = names[slot]
    if index and shown[slot] then
      local x, w = pill_frame(slot)
      if x and w then
        x_of[index] = x
        width_of[index] = w
        if not start_x or x < start_x then start_x = x end
        if prev_x and prev_w and not gap then gap = x - (prev_x + prev_w) end
        prev_x, prev_w = x, w
      end
    end
  end
  gap = gap or 0

  local kept_icons, kept_empty = {}, {}
  for slot = 1, MAX_SPACES do
    local index = names[slot]
    if index then
      kept_icons[index] = icon_lines[slot]
      kept_empty[index] = empty[slot]
    end
  end

  if seq ~= rearrange_seq then
    finish_rearrange(focused, seq)
    return
  end

  bind_order(ordered)
  hide_outlines()
  local cursor = start_x
  for slot = 1, MAX_SPACES do
    local index = names[slot]
    if index then
      icon_lines[slot] = kept_icons[index]
      if kept_empty[index] ~= nil then empty[slot] = kept_empty[index] end
      shown[slot] = true
      hiding[slot] = nil
      local dx = 0
      local width = width_of[index] or 36
      if cursor and x_of[index] then dx = x_of[index] - cursor end
      if cursor then cursor = cursor + width + gap end
      spaces[slot]:set({ drawing = true, x_offset = dx, y_offset = 0 })
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
  hide_outlines()
  sbar.animate("tanh", 22, function()
    for slot = 1, MAX_SPACES do
      if names[slot] then spaces[slot]:set({ x_offset = 0 }) end
    end
  end)
  sbar.delay(0.38, function()
    finish_rearrange(focused, seq)
    for slot = 1, MAX_SPACES do
      if names[slot] then update_windows(slot) end
    end
  end)
end

local function schedule_rearrange(ordered, focused)
  local key = list_key(ordered)
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
    animate_rearrange(ordered, focused, seq)
  end)
end

-- Reconcile generation: rapid switching debounces into one query burst,
-- and late callbacks from superseded switches are dropped instead of
-- repainting stale state out of order.
local reconcile_gen = 0
local reconcile

-- One --spaces query answers everything: which indices exist, which hold
-- windows, and (via `visible[focused]`) which must stay revealed. Space
-- objects nest no braces, so %b{} splits the JSON array without a parser.
-- YBAR PORT: right after wake (or login) yabai can take a few seconds to
-- answer, and no parseable spaces means "not ready" (a running yabai always
-- reports at least one) — retry a few times instead of blanking the bar.
reconcile = function(focused, attempt, gen)
  sbar.exec(yabai .. " -m query --spaces 2>/dev/null", function(out)
    if gen ~= reconcile_gen then return end
    -- The menus may have swapped in while this query was in flight; a
    -- reveal now would draw pills over the open app menus, and nothing
    -- hides them again until the next swap.
    if MENUS_VISIBLE or reordering then return end
    local visible = {}
    local found = false
    for obj in out:gmatch("%b{}") do
      local sid = tonumber(obj:match('"index"%s*:%s*(%d+)'))
      if sid then
        found = true
        local has_windows = obj:match('"windows"%s*:%s*%[%s*%d') ~= nil
        if spaces[sid] then empty[sid] = not has_windows end
        if has_windows then visible[sid] = true end
      end
    end
    if not found and (attempt or 0) < 5 then
      sbar.exec("sleep 2", function()
        if gen == reconcile_gen then reconcile(focused, (attempt or 0) + 1, gen) end
      end)
      return
    end
    if focused then visible[focused] = true end

    if YSUITE_LIQUID then
      local promoted = promoted_order(visible, focused)
      local ordered
      if not liquid_ordered_once then
        ordered = promoted
        liquid_ordered_once = true
        pending_order_key = ""
      else
        ordered = stable_order(visible, focused)
        if lists_equal(ordered, promoted) then
          rearrange_seq = rearrange_seq + 1
          pending_order_key = ""
        else
          schedule_rearrange(promoted, focused)
        end
      end
      bind_order(ordered)
      for slot = 1, MAX_SPACES do
        if names[slot] then
          reveal_pill(slot)
          update_windows(slot)
        elseif shown[slot] and not hiding[slot] then
          collapse_pill(slot)
        end
      end
    else
      for sid in pairs(spaces) do
        if visible[sid] then
          reveal_pill(sid)
          update_windows(sid)
        elseif shown[sid] and not hiding[sid] then
          collapse_pill(sid)
        end
      end
    end
  end)
end

local function update_spaces(focused, reset_icons)
  if reset_icons then arm_icon_timer() end
  if focused then
    apply_focus(focused)          -- instant, per switch
  end
  reconcile_gen = reconcile_gen + 1
  local gen = reconcile_gen
  sbar.delay(0.12, function()     -- debounce: one reconcile after a burst
    if gen == reconcile_gen then reconcile(focused, 0, gen) end
  end)
end

local space_observer = sbar.add("item", {
  drawing = false,
  updates = true,
  update_freq = 5,
})

-- Query the focused space and repaint — every refresh path funnels through
-- here (space_change carries no index), with retries while yabai is still
-- starting up. yabai absent entirely: five quiet retries, then nothing.
local function query_and_update(attempt, reset_icons)
  sbar.exec(yabai .. " -m query --spaces --space 2>/dev/null", function(out)
    local focused = tonumber(out:match('"index"%s*:%s*(%d+)'))
    if not focused and (attempt or 0) < 5 then
      sbar.exec("sleep 2", function() query_and_update((attempt or 0) + 1, reset_icons) end)
      return
    end
    if MENUS_VISIBLE then return end
    update_spaces(focused, reset_icons)
  end)
end

-- MENUS_VISIBLE (set by menus.lua) guards every refresh path so a resync
-- can't resurrect the space pills while the app menus are shown.
space_observer:subscribe("space_change", function()
  if MENUS_VISIBLE then return end
  query_and_update(nil, true)
end)

-- menus.lua's swap-back fires this (with an empty FOCUSED_WORKSPACE when
-- AeroSpace is absent) to restore the pills; treat it as a plain resync.
space_observer:subscribe("aerospace_workspace_change", function()
  if MENUS_VISIBLE then return end
  -- menus.lua uses this to restore pills after a swap. Not a workspace change.
  query_and_update()
end)

-- space_change doesn't fire after sleep unless the space actually changed,
-- so the pills stay stale or hidden — resync on the daemon's system_woke.
space_observer:subscribe("system_woke", function() query_and_update() end)

-- Apps opening and closing repaint the pills immediately —
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

-- yabai signals give instant window-level updates when configured
-- (examples/yabai-skhd/yabairc); the routine poll below stays as the
-- fallback when they are not.
space_observer:subscribe({ "yabai_space_change", "yabai_window_change" }, function()
  if MENUS_VISIBLE then return end
  query_and_update(nil, true)
end)

-- Minimize/window-close emit no OS-level event at all — a light routine
-- poll reconciles those within seconds (redundant once signals are wired,
-- but harmless).
space_observer:subscribe("routine", function() query_and_update() end)

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
