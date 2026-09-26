local colors = require("colors")
local settings = require("settings")
local hover = require("helpers.hover")

-- YBAR PORT: the tray for background apps' native menu bar items (Proton,
-- OneDrive, Creative Cloud, …). The statusitems helper enumerates them
-- through the Accessibility API and can press one even while the native menu
-- bar is hidden.
--
-- It expands IN THE BAR rather than dropping a popup: the chevron opens the
-- capsule leftwards and the items slide out as their real app icons, the
-- same reveal the workspace pills use. Clicking one presses the real status
-- item, so macOS draws that app's own menu — which is why there is no menu
-- rendering here at all any more, no drill-down, and no 48-row pool to
-- compact onto a short display.
--
-- Left-click an icon opens its menu; right-click hides it (persisted); ⌥
-- while open reveals the hidden ones.

-- Twelve is about two hands of background apps, and each one costs the bar
-- its icon width while open. Anything past this stays hidden behind ⌥.
local MAX_SLOTS = 12
local slot_w = 22
local slot_gap = 4

local helper = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/bin/statusitems"
local hidden_file = os.getenv("HOME") .. "/.config/ybar-hidden-items"

-- ── Bar pill: the toggle ───────────────────────────────────────────────────
local chevron = sbar.add("item", "widgets.menubar", {
  position = "right",
  icon = {
    string = "‹",
    font = { size = 17, style = settings.font.style_map["Bold"] },
    color = colors.white,
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
  padding_left = 2,
  padding_right = 2,
  -- Carries the routine tick the refresh rides on.
  update_freq = 10,
})

-- Created after the chevron, so the strip grows to its LEFT: right-positioned
-- items are laid out from the right edge in creation order.
local slots = {}
for i = 1, MAX_SLOTS do
  slots[i] = sbar.add("item", "widgets.menubar.slot." .. i, {
    position = "right",
    drawing = false,
    width = 0,
    padding_left = 0,
    padding_right = 0,
    background = { drawing = false },
    icon = { drawing = false },
    label = { drawing = false },
    image = {
      string = "",
      size = slot_w - 4,
      padding_left = 0,
      padding_right = 0,
    },
  })
end

-- One capsule around the toggle and the whole strip, so expanding reads as
-- the tray opening rather than a row of loose icons appearing beside it.
local members = { chevron.name }
for i = 1, MAX_SLOTS do members[#members + 1] = slots[i].name end
local bracket = sbar.add("bracket", "widgets.menubar.bracket", members, {
  background = { color = colors.bg1 },
})

sbar.add("item", "widgets.menubar.padding", {
  position = "right",
  width = settings.group_paddings,
})

local watchers = { bracket, chevron }
for i = 1, MAX_SLOTS do watchers[#watchers + 1] = slots[i] end
hover.attach(bracket, watchers, colors.bg1, colors.bg2)

-- ── State ──────────────────────────────────────────────────────────────────
local items_cache = {}    -- { pid, name, index, count, hidden }
local shown = {}          -- slot i -> items_cache entry
local hidden_set = {}
local show_hidden = false
local no_access = false
local expanded = false
local collapse_seq = 0

local function load_hidden()
  hidden_set = {}
  local f = io.open(hidden_file, "r")
  if not f then return end
  for line in f:lines() do
    if line ~= "" then hidden_set[line] = true end
  end
  f:close()
end

local function save_hidden()
  os.execute("mkdir -p '" .. os.getenv("HOME") .. "/.config'")
  local f = io.open(hidden_file, "w")
  if not f then return end
  for name in pairs(hidden_set) do f:write(name, "\n") end
  f:close()
end

-- "CleanMyMac Menu" -> "CleanMyMac": strip helper-app suffixes for display.
local function pretty_name(name)
  return (name:gsub(" Menu$", ""):gsub(" Helper$", ""):gsub(" Agent$", ""))
end

local function display_name(entry)
  local name = pretty_name(entry.name)
  if entry.count > 1 then
    return name .. " (" .. (entry.index + 1) .. ")"
  end
  return name
end

local shell_quote = function(v) return "'" .. tostring(v):gsub("'", "'\\''") .. "'" end

-- ── The strip ──────────────────────────────────────────────────────────────
-- Which entries the strip would show. Hidden ones are held back unless ⌥ is
-- down, and the cap is the slot pool.
local function visible_entries()
  local out = {}
  for _, entry in ipairs(items_cache) do
    entry.hidden = hidden_set[display_name(entry)] == true
    if (not entry.hidden or show_hidden) and #out < MAX_SLOTS then
      out[#out + 1] = entry
    end
  end
  return out
end

-- Fills the slots without animating: used while already open, when the set
-- changes under us (an app quits, an item is hidden).
local function paint(animated)
  shown = no_access and {} or visible_entries()
  local function apply()
    for i, slot in ipairs(slots) do
      local entry = expanded and shown[i] or nil
      if entry then
        slot:set({
          drawing = true,
          width = slot_w,
          padding_left = slot_gap / 2,
          padding_right = slot_gap / 2,
          image = {
            drawing = true,
            string = "app." .. entry.name,
            -- A hidden item revealed by ⌥ reads as provisional rather than as
            -- one you kept. The image part has no alpha, and desaturate says
            -- "set aside" more plainly than a fade would anyway.
            desaturate = entry.hidden,
          },
        })
      else
        -- Width alone carries the collapse: the slot slides shut and
        -- retire_empty_slots stops drawing it once it has.
        slot:set({ width = 0, padding_left = 0, padding_right = 0 })
      end
    end
  end
  if animated then
    sbar.animate("tanh", 13, apply)
  else
    apply()
  end
end

-- A collapsed slot keeps its item alive at zero width; drawing=false only
-- after the animation, or it would vanish instead of sliding shut.
local function retire_empty_slots()
  collapse_seq = collapse_seq + 1
  local seq = collapse_seq
  sbar.delay(0.24, function()
    if seq ~= collapse_seq then return end
    for i, slot in ipairs(slots) do
      if not (expanded and shown[i]) then slot:set({ drawing = false }) end
    end
  end)
end

local function set_expanded(open)
  expanded = open
  chevron:set({ icon = { string = open and "›" or "‹" } })
  if open then
    collapse_seq = collapse_seq + 1   -- cancel a pending retire
    for i, slot in ipairs(slots) do
      if shown[i] or no_access then slot:set({ drawing = true }) end
    end
  end
  paint(true)
  if not open then retire_empty_slots() end
end

local function refresh()
  sbar.exec("'" .. helper:gsub("'", "'\\''") .. "' list 2>/dev/null", function(out)
    no_access = out:match("NOAX") ~= nil
    if not no_access then
      items_cache = {}
      for line in out:gmatch("[^\r\n]+") do
        local pid, name, index, count = line:match("^(%d+)\t(.-)\t(%d+)\t(%d+)$")
        if pid then
          items_cache[#items_cache + 1] = {
            pid = pid,
            name = name,
            index = tonumber(index),
            count = tonumber(count),
          }
        end
      end
      table.sort(items_cache, function(a, b)
        return pretty_name(a.name):lower() < pretty_name(b.name):lower()
      end)
    end
    -- Only repaint while open: a refresh behind a closed tray has nothing to
    -- show and would animate slots nobody can see.
    if expanded then
      for i, slot in ipairs(slots) do
        if visible_entries()[i] then slot:set({ drawing = true }) end
      end
      paint(true)
      retire_empty_slots()
    end
  end)
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function collapse()
  if not expanded then return end
  set_expanded(false)
end

-- Accessibility is what the helper needs to see the items at all. Without it
-- the tray has nothing to open, so the toggle sends you to the pane instead.
local function toggle(env)
  if no_access then
    sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
    return
  end
  if expanded then return collapse() end
  show_hidden = (env and env.MODIFIER == "alt") or false
  set_expanded(true)
  refresh()
end

chevron:subscribe("mouse.clicked", toggle)
chevron:subscribe("mouse.exited.global", collapse)

for i, slot in ipairs(slots) do
  slot:subscribe("mouse.clicked", function(env)
    local entry = shown[i]
    if not entry then return end
    if env.BUTTON == "right" then
      local key = display_name(entry)
      hidden_set[key] = not hidden_set[key] or nil
      save_hidden()
      paint(true)
      retire_empty_slots()
      return
    end
    -- Press the real status item: macOS opens that app's own menu, anchored
    -- to where the item would be. Collapse first so the strip is not left
    -- standing open underneath it.
    collapse()
    sbar.delay(0.2, function()
      sbar.exec(shell_quote(helper) .. " press " .. entry.pid .. " " .. entry.index)
    end)
  end)
end

-- Live reveal: holding ⌥ while the strip is open brings the hidden ones in,
-- releasing takes them back out.
chevron:subscribe("modifier_change", function(env)
  if not expanded then return end
  local want = env.MODIFIER == "alt"
  if want == show_hidden then return end
  show_hidden = want
  for i in ipairs(slots) do
    if visible_entries()[i] then slots[i]:set({ drawing = true }) end
  end
  paint(true)
  retire_empty_slots()
end)

-- The set changes without any click: apps launch, quit, add a second item.
chevron:subscribe({ "routine", "app_launched", "app_terminated", "system_woke" },
  function() refresh() end)

load_hidden()
refresh()
