local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- WINDOWS PORT, new widget: the notification area (system tray), because a bar
-- that hides the shell taskbar otherwise leaves no way to reach the icons that
-- live there — NVIDIA Settings, Radeon Software, OneDrive, antivirus.
--
-- These are NOT windows: they are Shell_NotifyIcon registrations owned by
-- Explorer, so the running-apps enumeration cannot see them. `ybar --query
-- tray` reads them through UI Automation (see src/providers/tray_icons.cpp;
-- the legacy ToolbarWindow32 technique is dead on Windows 11 22H2+), and
-- `ybar --tray "<name>" invoke` activates one — Explorer forwards that to the
-- owning app as the real tray callback, exactly like clicking it in the
-- taskbar.
--
-- Icon pixels come from the registry's IconSnapshot PNGs, matched to labels by
-- string; roughly half match confidently, and the rest fall back to a neutral
-- glyph rather than risk showing the WRONG app's icon.

local popup_width = 268
local inset = 11
local MAX_ROWS = 12
local ICON_W = 26

local tray = sbar.add("item", "widgets.apps", {
  position = "right",
  icon = {
    string = icons.apple,          -- sf:apps — the Start-like grid glyph
    font = { size = 13 },
    color = colors.white,
    padding_left = 7,
    padding_right = 7,
  },
  label = { drawing = false },
  padding_left = 2,
  padding_right = 2,
})

local tray_bracket = sbar.add("bracket", "widgets.apps.bracket", { tray.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 26 },
})

sbar.add("item", "widgets.apps.padding", {
  position = "right",
  width = settings.group_paddings,
})

local popup_pos = "popup." .. tray_bracket.name

local header = sbar.add("item", "widgets.apps.header", {
  position = popup_pos,
  width = popup_width,
  align = "left",
  icon = {
    string = "Tray",
    align = "left",
    font = { size = 12.5, style = settings.font.style_map["Bold"] },
    width = popup_width / 2,
    padding_left = inset,
  },
  label = {
    string = "",
    align = "right",
    color = colors.grey,
    font = { size = 10.5 },
    width = popup_width / 2,
    padding_right = inset,
  },
  background = { height = 2, color = colors.grey, y_offset = -13 },
})

-- Fixed row pool. The image carries the tray icon's PNG when one matched; the
-- NAME lives in the icon part as plain text. Never mix a PUA glyph into a text
-- part — symbol fonts do not font-fall-back (see wifi.lua).
local rows = {}
for i = 1, MAX_ROWS do
  rows[i] = sbar.add("item", "widgets.apps.row." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    align = "left",
    image = {
      string = "",
      size = 16,
      drawing = false,
      padding_left = inset,
      padding_right = 8,
    },
    icon = {
      string = "",
      align = "left",
      color = colors.white,
      font = { size = 11.5 },
      width = popup_width - inset - ICON_W,
      padding_left = 0,
    },
    label = { drawing = false },
  })
end

sbar.add("item", "widgets.apps.sep", {
  position = popup_pos,
  width = popup_width,
  icon = { drawing = false },
  label = { drawing = false },
  background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
})

local taskmgr_row = sbar.add("item", "widgets.apps.taskmgr", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "Task Manager",
    align = "left",
    color = colors.white,
    font = { size = 10.5 },
    width = popup_width - inset,
    padding_left = inset,
  },
  label = { drawing = false },
})

-- ── State ──────────────────────────────────────────────────────────────────
local cache = {}   -- row index -> tray icon name

local function hide_popup()
  tray_bracket:set({ popup = { drawing = false } })
end

local function populate()
  local list = sbar.query("tray") or {}
  cache = {}
  local shown = 0
  for _, entry in ipairs(list) do
    if shown >= MAX_ROWS then break end
    shown = shown + 1
    cache[shown] = entry.name
    local has_icon = entry.icon and entry.icon ~= ""
    rows[shown]:set({
      drawing = true,
      image = { string = has_icon and entry.icon or "", drawing = has_icon or false },
      icon = {
        string = entry.name or "?",
        -- No matched PNG: indent to the same column the icons occupy so the
        -- labels still line up.
        padding_left = has_icon and 0 or (ICON_W + inset),
        color = colors.white,
      },
    })
  end
  for i = shown + 1, MAX_ROWS do rows[i]:set({ drawing = false }) end
  header:set({ label = { string = shown > 0 and (shown .. " items") or "none" } })
end

-- ── Interactions ───────────────────────────────────────────────────────────
for i = 1, MAX_ROWS do
  rows[i]:subscribe("mouse.clicked", function()
    local name = cache[i]
    if not name then return end
    -- Invoke opens the app's own tray UI (its window or context menu), so the
    -- popup should get out of the way.
    hide_popup()
    sbar.exec('ybar --tray "' .. name:gsub('"', "") .. '" invoke')
  end)
end

taskmgr_row:subscribe("mouse.clicked", function()
  hide_popup()
  sbar.exec("taskmgr.exe")
end)

local function toggle_popup()
  local should_draw = tray_bracket:query().popup.drawing == "off"
  if should_draw then
    populate()
    tray_bracket:set({ popup = { drawing = true } })
  else
    hide_popup()
  end
end

tray:subscribe("mouse.clicked", toggle_popup)
tray:subscribe("mouse.exited.global", hide_popup)
