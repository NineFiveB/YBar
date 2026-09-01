local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- WINDOWS PORT, new widget: a running-apps list, because a bar that hides the
-- shell taskbar otherwise leaves no way to see or close what is running.
--
-- This is NOT the tray-icon mirror spec 10.6 rules out (Explorer's tray
-- buttons still have no per-icon capture API). It is the alt-tab list:
-- `ybar --query windows` runs the engine's top-level window enumeration
-- (src/providers/window_list.cpp) and returns one entry per application,
-- already grouped, with the exe path for the icon. The query is synchronous
-- and in-process, so the popup opens from live data with no subprocess.
--
-- Click semantics: left-click closes the app's front window gracefully
-- (WM_CLOSE — the app still gets to prompt about unsaved work); right-click
-- arms a two-step force quit. Force-quitting on one unconfirmed click in a
-- hover-dismissed popup is far too easy to hit by accident.

local popup_width = 268
local inset = 11
local MAX_APPS = 10
local ICON_W = 26
local COUNT_W = 44

local apps = sbar.add("item", "widgets.apps", {
  position = "right",
  icon = {
    string = icons.apple,          -- sf:apps — the Start-like app grid glyph
    font = { size = 13 },
    color = colors.white,
    padding_left = 7,
    padding_right = 7,
  },
  label = { drawing = false },
  padding_left = 2,
  padding_right = 2,
})

local apps_bracket = sbar.add("bracket", "widgets.apps.bracket", { apps.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 26 },
})

sbar.add("item", "widgets.apps.padding", {
  position = "right",
  width = settings.group_paddings,
})

local popup_pos = "popup." .. apps_bracket.name

-- ── Header ─────────────────────────────────────────────────────────────────
local header = sbar.add("item", "widgets.apps.header", {
  position = popup_pos,
  width = popup_width,
  align = "left",
  icon = {
    string = "Running Apps",
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

-- ── Row pool ───────────────────────────────────────────────────────────────
-- image = the real app icon (engine resolves "exe.<path>" through
-- SHGetFileInfoW). The NAME lives in the icon part and the window count in
-- the label: never mix a PUA glyph into a text part (symbol fonts do not
-- font-fall-back — see wifi.lua).
local rows = {}
for i = 1, MAX_APPS do
  rows[i] = sbar.add("item", "widgets.apps.row." .. i, {
    position = popup_pos,
    drawing = false,
    width = popup_width,
    align = "left",
    image = {
      string = "",
      size = 16,
      drawing = true,
      padding_left = inset,
      padding_right = 8,
    },
    icon = {
      string = "",
      align = "left",
      color = colors.white,
      font = { size = 11.5 },
      width = popup_width - inset - ICON_W - COUNT_W,
    },
    label = {
      string = "",
      align = "right",
      color = colors.grey,
      font = { size = 10.5 },
      width = COUNT_W,
      padding_right = inset,
    },
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
local cache = {}      -- row index -> { name, hwnd, pid, count }
local armed = nil     -- row index awaiting force-quit confirmation
local armed_gen = 0

local function hide_popup()
  apps_bracket:set({ popup = { drawing = false } })
end

local function disarm()
  if not armed then return end
  local i = armed
  armed = nil
  local entry = cache[i]
  if entry then
    rows[i]:set({
      icon = { string = entry.name, color = colors.white },
      label = { string = entry.count > 1 and (entry.count .. " windows") or "" },
    })
  end
end

local function populate()
  local list = sbar.query("windows") or {}
  cache = {}
  local shown = 0
  for _, app in ipairs(list) do
    if shown >= MAX_APPS then break end
    shown = shown + 1
    local count = app.window_count or 1
    local first = app.windows and app.windows[1] or nil
    cache[shown] = {
      name = app.name or "?",
      hwnd = first and first.hwnd or nil,
      pid = app.pid,
      count = count,
    }
    rows[shown]:set({
      drawing = true,
      image = { string = (app.executable and app.executable ~= "")
        and ("exe." .. app.executable) or "", drawing = true },
      icon = { string = app.name or "?", color = colors.white },
      label = { string = count > 1 and (count .. " windows") or "" },
    })
  end
  for i = shown + 1, MAX_APPS do rows[i]:set({ drawing = false }) end
  header:set({ label = { string = shown > 0 and (shown .. " apps") or "none" } })
  armed = nil
end

-- ── Interactions ───────────────────────────────────────────────────────────
for i = 1, MAX_APPS do
  rows[i]:subscribe("mouse.clicked", function(env)
    local entry = cache[i]
    if not entry or not entry.hwnd then return end
    local force = (env and env.BUTTON == "right")
      or (env and env.MODIFIER == "shift")

    if force then
      if armed == i then
        sbar.exec("ybar --window " .. entry.hwnd .. " kill")
        armed = nil
        sbar.delay(0.4, populate)
      else
        disarm()
        armed = i
        armed_gen = armed_gen + 1
        local gen = armed_gen
        rows[i]:set({
          icon = { string = "Force quit " .. entry.name .. "?", color = colors.red },
          label = { string = "" },
        })
        -- Auto-disarm: a stale armed row must never turn a later stray click
        -- into a kill.
        sbar.delay(3, function() if armed_gen == gen then disarm() end end)
      end
      return
    end

    disarm()
    -- Front window only. Fanning WM_CLOSE across every window of a group
    -- pops a save dialog per window, including ones parked on another
    -- workspace with no visible owner.
    sbar.exec("ybar --window " .. entry.hwnd .. " close")
    sbar.delay(0.6, populate)
  end)
end

taskmgr_row:subscribe("mouse.clicked", function()
  sbar.exec("taskmgr.exe")
  hide_popup()
end)

local function toggle_popup()
  local should_draw = apps_bracket:query().popup.drawing == "off"
  if should_draw then
    populate()
    apps_bracket:set({ popup = { drawing = true } })
  else
    hide_popup()
  end
end

apps:subscribe("mouse.clicked", toggle_popup)
apps:subscribe("mouse.exited.global", function()
  disarm()
  hide_popup()
end)

-- Keep the list current while it is open; these events already exist and
-- already arm the engine's 2 s lifecycle poller when subscribed.
apps:subscribe({ "app_launched", "app_terminated" }, function()
  if apps_bracket:query().popup.drawing == "on" then populate() end
end)
