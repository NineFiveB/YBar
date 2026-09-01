local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- WINDOWS PORT, new widget: the notification area (system tray), because a bar
-- that hides the shell taskbar otherwise leaves no way to reach the icons that
-- live there — NVIDIA Settings, Radeon Software, OneDrive, antivirus.
--
-- These are NOT windows: they are Shell_NotifyIcon registrations owned by
-- Explorer, so the running-apps enumeration cannot see them. `ybar --query
-- tray` reads Explorer's registration list and reports the entries whose owner
-- is running; `ybar --tray "<name>" invoke` activates one. See
-- src/providers/tray_icons.cpp for why that beats the UI Automation walk it
-- replaced (which saw only the icons promoted onto the taskbar — 1 of 11 here —
-- and reported an empty label for a third of the rest).
--
-- Rows carry the real tray icon. That only became possible when the list moved
-- to the registry: the pixels live in the SAME key as the name (IconSnapshot,
-- a literal PNG), so there is nothing to match. While the list came from UI
-- Automation the two had no id in common and had to be paired by string, which
-- matched 6 of 14 and risked showing the WRONG app's icon — hence the earlier
-- text-only rows. `--query tray` now hands back a ready path per row.
--
-- Caveat worth knowing: the snapshot is captured at FIRST registration, so an
-- icon that encodes live state (sync progress, battery) can render stale. For
-- app identity — which is all this list is for — it is exactly right.

local popup_width = 268
local inset = 11
local MAX_ROWS = 16
-- Leading gutter for the icon column, matched to the bluetooth popup's 35pt
-- glyph column so both popups' text columns start at the same x.
local gutter = 35
local icon_size = 14

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

-- Fixed row pool; the NAME lives in the icon part as plain text.
local rows = {}
for i = 1, MAX_ROWS do
  rows[i] = sbar.add("item", "widgets.apps.row." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    align = "left",
    image = {
      string = "",
      size = icon_size,
      padding_left = inset,
      padding_right = gutter - inset - icon_size,
      -- An image centres on the row's em box, but text ink sits below that
      -- centre, so the icon has to come DOWN (y_offset is positive-up) to land
      -- on the label's optical centre. Nudging the text instead also resizes
      -- the row, which never converges.
      y_offset = -1.5,
    },
    icon = {
      string = "",
      align = "left",
      color = colors.white,
      font = { size = 11.5 },
      width = popup_width - gutter,
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
    rows[shown]:set({
      drawing = true,
      -- An empty source simply draws nothing, so a row with no resolvable
      -- icon degrades to the old text-only look rather than breaking.
      image = { string = entry.icon or "" },
      icon = { string = entry.name or "?", color = colors.white },
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
