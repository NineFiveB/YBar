local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- YBAR PORT: Bartender-style collapsible menu for background apps'
-- native menu bar items (Proton, OneDrive, Creative Cloud, …). The
-- statusitems helper enumerates them via the Accessibility API and can
-- press one to open its real menu even while the native menu bar is
-- auto-hidden. Left-click a row opens the item's menu; right-click
-- hides/restores it (persisted); "Show Hidden" reveals the hidden set.

local popup_width = 280
local inset = 12
local max_rows = 12

local helper = (PORT_DIR or (os.getenv("HOME") .. "/.config/ybar"))
  .. "/helpers/bin/statusitems"
local hidden_file = os.getenv("HOME") .. "/.config/ybar-hidden-items"

-- ── Bar pill: the Bartender chevron ────────────────────────────────────────
local chevron = sbar.add("item", "widgets.menubar", {
  position = "right",
  icon = {
    string = "‹",
    font = { size = 17, style = settings.font.style_map["Bold"] },
    color = colors.grey,
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
    string = "Menu Bar Items",
    font = { size = 14, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    align = "right",
    string = "",
    color = colors.grey,
    width = popup_width / 2,
    padding_right = inset,
  },
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
end

sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local show_hidden_row = sbar.add("item", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "Show Hidden",
    align = "left",
    color = colors.white,
    font = { size = 12.0 },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = "",
    align = "right",
    color = colors.grey,
    font = { size = 11.0, style = settings.font.style_map["Semibold"] },
    width = popup_width / 2,
    padding_right = inset,
  },
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
local refreshing = false

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local spinner_index = 0

local function spin()
  if not refreshing then
    header:set({ label = { string = "" } })
    return
  end
  spinner_index = spinner_index % #spinner_frames + 1
  header:set({ label = { string = spinner_frames[spinner_index] } })
  sbar.delay(0.1, spin)
end

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

local function populate()
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
        image = { string = "app." .. entry.name },
        label = {
          string = display_name(entry) .. (entry.hidden and "  ·  hidden" or ""),
          color = entry.hidden and colors.grey or colors.white,
        },
      })
    else
      row:set({ drawing = false })
    end
  end

  show_hidden_row:set({
    drawing = not no_access,
    icon = { string = show_hidden and "Hide Hidden" or "Show Hidden" },
    label = { string = hidden_count > 0 and tostring(hidden_count) or "" },
  })
  hint_row:set({ drawing = not no_access })
end

local function refresh()
  refreshing = true
  spin()
  sbar.exec("'" .. helper:gsub("'", "'\\''") .. "' list 2>/dev/null", function(out)
    refreshing = false
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
  bracket:set({ popup = { drawing = false } })
end

for i, row in ipairs(rows) do
  row:subscribe("mouse.clicked", function(env)
    local entry = visible_map[i]
    if not entry then return end
    if env.BUTTON == "right" then
      local key = display_name(entry)
      hidden_set[key] = not hidden_set[key] or nil
      save_hidden()
      populate()
      return
    end
    hide_popup()
    sbar.delay(0.2, function()
      sbar.exec("'" .. helper:gsub("'", "'\\''") .. "' press "
        .. entry.pid .. " " .. entry.index)
    end)
  end)
end

show_hidden_row:subscribe("mouse.clicked", function()
  show_hidden = not show_hidden
  populate()
end)

access_row:subscribe("mouse.clicked", function()
  sbar.exec("open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'")
  hide_popup()
end)

local function toggle_popup()
  local should_draw = bracket:query().popup.drawing == "off"
  if should_draw then
    bracket:set({ popup = { drawing = true } })
    populate()
    refresh()
  else
    hide_popup()
  end
end

chevron:subscribe("mouse.clicked", toggle_popup)
chevron:subscribe("mouse.exited.global", hide_popup)

load_hidden()
refresh()
