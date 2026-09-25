local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local hover = require("helpers.hover")

-- YBAR PORT: Bartender-style collapsible menu for background apps'
-- native menu bar items (Proton, OneDrive, Creative Cloud, …). The
-- statusitems helper enumerates them via the Accessibility API and can
-- press one to open its real menu even while the native menu bar is
-- auto-hidden. Left-click a row opens the item's menu; right-click
-- hides/restores it (persisted); "Show Hidden" reveals the hidden set.

local popup_width = 280
local inset = 12
-- Enough rows for a real app menu, not just the item list: Raycast's has 13
-- entries and AeroSpace's 43. Unused rows are hidden, so the only cost of a
-- generous cap is that many item objects.
local max_rows = 26

local helper = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/bin/statusitems"
local hidden_file = os.getenv("HOME") .. "/.config/ybar-hidden-items"

-- ── Bar pill: the Bartender chevron ────────────────────────────────────────
local chevron = sbar.add("item", "widgets.menubar", {
  position = "right",
  icon = {
    string = "‹",
    font = { size = 17, style = settings.font.style_map["Bold"] },
    color = colors.white,
    padding_left = 8,
    padding_right = 8,
    y_offset = 1,
  },
  label = { drawing = false },
  padding_left = 2,
  padding_right = 2,
})

local bracket = sbar.add("bracket", "widgets.menubar.bracket", { chevron.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 },
})

hover.pill(bracket, chevron)

sbar.add("item", "widgets.menubar.padding", {
  position = "right",
  width = settings.group_paddings,
})

local popup_pos = "popup." .. bracket.name

local header = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    align = "left",
    string = "Background",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    padding_left = inset,
  },
  -- No label slot: the refresh spinner (image, align=r) trails the title.
  label = { drawing = false },
  align = "left",
  background = { height = 2, color = colors.grey, y_offset = -15 },
})

-- Shown only when Accessibility permission is missing.
local access_row = sbar.add("item", {
  position = popup_pos,
  drawing = false,
  width = popup_width,
  icon = {
    string = "Accessibility access needed",
    align = "left",
    color = colors.grey,
    font = { size = 12.0 },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = "Open Privacy",
    align = "right",
    color = colors.white,
    font = { size = 12.0, style = settings.font.style_map["Semibold"] },
    width = popup_width / 2,
    padding_right = inset,
  },
})
hover.row(access_row)

local rows = {}
for i = 1, max_rows do
  rows[i] = sbar.add("item", "widgets.menubar.row." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    icon = { drawing = false },
    -- Real app icons via the engine's image component ("app.<Name>").
    image = {
      string = "",
      size = 18,
      padding_left = inset + 4,
      padding_right = 8,
    },
    label = {
      string = "",
      color = colors.white,
      font = { size = 12.0 },
      width = popup_width - 18 - inset - 12,
      align = "left",
    },
  })
  hover.row(rows[i])
end

sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local hint_row = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  align = "center",
  icon = {
    string = "click opens · right-click hides",
    color = colors.with_alpha(colors.grey, 0.7),
    font = { size = 10.0 },
  },
  label = { drawing = false },
})

-- ── State ──────────────────────────────────────────────────────────────────
local items_cache = {}    -- { pid, name, index, count, hidden }
local visible_map = {}    -- row i -> items_cache entry
local hidden_set = {}
local show_hidden = false
local no_access = false
-- Drill-down: nil at the item list, else the app whose menu is on screen.
-- `path` is the helper's dot-separated index chain, so a submenu is one
-- level deeper and "back" is a single pop.
local menu_view = nil     -- { entry = <items_cache entry>, path = {…}, rows = {…} }
local refreshing = false

local spinner = require("helpers.spinner").attach(header)

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

-- Render the drilled-into menu: one row per entry, a back row on top.
-- Separators (blank, disabled) are dropped — they carry no text, and a row
-- that cannot be clicked is noise in a list this short.
local function populate_menu()
  access_row:set({ drawing = false })
  local view = menu_view
  local shown = {}
  for _, e in ipairs(view.rows) do
    if e.title ~= "" then shown[#shown + 1] = e end
  end
  view.shown = shown

  for i, row in ipairs(rows) do
    if i == 1 then
      row:set({
        drawing = true,
        image = { drawing = false },
        icon = { drawing = true, string = "‹", align = "left",
                 color = colors.grey, padding_left = inset + 4,
                 font = { size = 14, style = settings.font.style_map["Bold"] } },
        label = { string = display_name(view.entry), color = colors.grey },
      })
    else
      local e = shown[i - 1]
      if e then
        row:set({
          drawing = true,
          image = { drawing = false },
          icon = { drawing = true, string = e.submenu and "›" or " ", align = "right",
                   color = colors.grey, padding_left = 0,
                   padding_right = inset, font = { size = 12 } },
          label = {
            string = e.title,
            color = e.enabled and colors.white or colors.grey,
            padding_left = inset + 4,
          },
        })
      else
        row:set({ drawing = false })
      end
    end
  end
  local capacity = #rows - 1
  local hint = "click runs · ‹ back"
  if #shown > capacity then
    hint = hint .. " · " .. (#shown - capacity) .. " more not shown"
  end
  hint_row:set({ drawing = true, icon = { string = hint } })
end

local function populate()
  if menu_view then return populate_menu() end
  access_row:set({ drawing = no_access })

  local hidden_count = 0
  for _, entry in ipairs(items_cache) do
    entry.hidden = hidden_set[display_name(entry)] == true
    if entry.hidden then hidden_count = hidden_count + 1 end
  end

  visible_map = {}
  for _, entry in ipairs(items_cache) do
    if (not entry.hidden or show_hidden) and #visible_map < max_rows then
      visible_map[#visible_map + 1] = entry
    end
  end

  for i, row in ipairs(rows) do
    local entry = not no_access and visible_map[i] or nil
    if entry then
      row:set({
        drawing = true,
        image = { drawing = true, string = "app." .. entry.name },
        icon = { drawing = false },
        label = {
          string = display_name(entry) .. (entry.hidden and "  ·  hidden" or ""),
          color = entry.hidden and colors.grey or colors.white,
          padding_left = 0,
        },
      })
    else
      row:set({ drawing = false })
    end
  end

  local hint = "click opens · right-click hides"
  if hidden_count > 0 and not show_hidden then
    hint = hint .. " · hold ⌥ for " .. hidden_count .. " hidden"
  end
  hint_row:set({ drawing = not no_access, icon = { string = hint } })
end

local function refresh()
  refreshing = true
  spinner.start()
  sbar.exec("'" .. helper:gsub("'", "'\\''") .. "' list 2>/dev/null", function(out)
    refreshing = false
    spinner.stop()
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
    populate()
  end)
end

-- ── Interactions ───────────────────────────────────────────────────────────
local function hide_popup()
  -- Always leave at the item list: an auto-close (pointer leaving the bar)
  -- runs no Lua, so a popup reopened later would otherwise still be showing
  -- some app's menu with no memory of why.
  menu_view = nil
  bracket:set({ popup = { drawing = false } })
end

-- Load an app's menu (or a submenu) into the popup. Async: the helper reads
-- the AX tree of another process, which is not instant, and the popup must
-- not freeze the bar while it does.
local function open_menu(entry, path)
  local cmd = shell_quote(helper) .. " menu " .. entry.pid .. " " .. entry.index
  if #path > 0 then cmd = cmd .. " " .. table.concat(path, ".") end
  sbar.exec(cmd, function(out, code)
    -- No menu (Creative Cloud's icon opens a panel instead): fall back to
    -- pressing the item, which is what the widget always did.
    if code ~= 0 or not out:match("%S") then
      if #path == 0 then
        hide_popup()
        sbar.delay(0.2, function()
          sbar.exec(shell_quote(helper) .. " press " .. entry.pid .. " " .. entry.index)
        end)
      end
      return
    end
    local parsed = {}
    for line in out:gmatch("[^\n]+") do
      local idx, enabled, submenu, title = line:match("^(%d+)\t(%d)\t(%d)\t(.*)$")
      if idx then
        parsed[#parsed + 1] = {
          index = tonumber(idx), enabled = enabled == "1",
          submenu = submenu == "1", title = title,
        }
      end
    end
    menu_view = { entry = entry, path = path, rows = parsed }
    populate()
  end)
end

for i, row in ipairs(rows) do
  row:subscribe("mouse.clicked", function(env)
    -- Inside an app's menu the rows mean something else entirely.
    if menu_view then
      if i == 1 then
        -- Back: one level up, or out to the item list.
        if #menu_view.path == 0 then
          menu_view = nil
        else
          local up = {}
          for n = 1, #menu_view.path - 1 do up[n] = menu_view.path[n] end
          return open_menu(menu_view.entry, up)
        end
        return populate()
      end
      local e = menu_view.shown and menu_view.shown[i - 1]
      if not e or not e.enabled then return end
      local path = {}
      for n = 1, #menu_view.path do path[n] = menu_view.path[n] end
      path[#path + 1] = e.index
      if e.submenu then return open_menu(menu_view.entry, path) end
      local target = menu_view.entry
      hide_popup()
      sbar.exec(shell_quote(helper) .. " item " .. target.pid .. " " .. target.index
        .. " " .. table.concat(path, "."))
      return
    end

    local entry = visible_map[i]
    if not entry then return end
    if env.BUTTON == "right" then
      local key = display_name(entry)
      hidden_set[key] = not hidden_set[key] or nil
      save_hidden()
      populate()
      return
    end
    open_menu(entry, {})
  end)
end

access_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
  hide_popup()
end)

-- Option-click opens with the hidden set revealed (Bartender's idiom).
local function toggle_popup(env)
  local should_draw = bracket:query().popup.drawing == "off"
  if should_draw then
    menu_view = nil
    show_hidden = (env and env.MODIFIER == "alt") or false
    bracket:set({ popup = { drawing = true } })
    populate()
    refresh()
  else
    hide_popup()
  end
end

chevron:subscribe("mouse.clicked", toggle_popup)
chevron:subscribe("mouse.exited.global", hide_popup)

-- Live reveal: holding ⌥ while the popup is open shows the hidden set,
-- releasing hides it again (immune to click-routing quirks).
chevron:subscribe("modifier_change", function(env)
  if bracket:query().popup.drawing ~= "on" then return end
  local want = env.MODIFIER == "alt"
  if want ~= show_hidden then
    show_hidden = want
    populate()
  end
end)

load_hidden()
refresh()
