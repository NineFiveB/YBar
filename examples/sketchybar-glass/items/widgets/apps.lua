local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- WINDOWS PORT, new widget: the notification area (system tray), because a bar
-- that hides the shell taskbar otherwise leaves no way to reach the icons that
-- live there — NVIDIA Settings, Radeon Software, OneDrive, antivirus.
--
-- Left-click a row opens the app, un-minimising the window it already has.
-- RIGHT-click quits it, after the row asks to confirm. Quitting is the point
-- of a tray on a bar that hides the taskbar — a background app is otherwise
-- unreachable — and it follows Task Manager's "End task" semantics: WM_CLOSE
-- first, then a terminate for whatever ignored it (see closeTrayApp).
--
-- These are NOT windows: they are Shell_NotifyIcon registrations owned by
-- Explorer, so the running-apps enumeration cannot see them. `ybar --query
-- tray` reads Explorer's registration list and reports the entries whose owner
-- is running; `ybar --tray "<name>" invoke|close` acts on one. See
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
local icon_size = 16

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
  background = { color = colors.mica }, -- tint over the Mica material
  popup = { align = "center", height = 26 },
})

require("helpers.hover").pill(tray_bracket, tray)

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

-- Fixed row pool. The image carries the tray icon PNG; the NAME lives in the
-- icon part as plain text. Never mix a PUA glyph into a text part — symbol
-- fonts do not font-fall-back (see wifi.lua), which is why the icon is an
-- image component rather than a glyph.
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
      -- An image centres on the row's em box, but the label's CAP band sits a
      -- little below that centre, so the icon comes down slightly to match it
      -- (y_offset is positive-up). Nudging the text instead also resizes the
      -- row, which never converges.
      --
      -- Measured at 2x on a row with a solid-square icon: cap band 135..151
      -- (centre 143) against icon 134..165 (centre 149.5). This was -4, which
      -- overshot by ~6px and left every icon visibly riding low against its
      -- name; -1 lands the two centres within half a pixel.
      y_offset = -1,
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
  require("helpers.hover").row(rows[i])
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
    -- 0.38/0.62, not half-and-half: the hint's ink is ~150pt at 9.5pt and a
    -- fixed slot clips from the ALIGNED side, so an even split shipped the
    -- hint as "k to open ...". "Task Manager" needs far less than half.
    width = popup_width * 0.38,
    padding_left = inset,
  },
  -- Neither gesture is discoverable on its own, and the cost of guessing the
  -- destructive one wrong is a killed app, so both are spelled out rather
  -- than left to be stumbled into.
  label = {
    string = "click to open · right-click to quit",
    align = "right",
    color = colors.grey,
    font = { size = 9.5 },
    width = popup_width * 0.62,
    padding_right = inset,
  },
})

-- ── State ──────────────────────────────────────────────────────────────────
local cache = {}   -- row index -> tray icon name

-- Right-click quits, but never on the first click: the row arms itself and asks
-- again. A tray list is a dense column of small targets and quitting is not
-- undoable, so one stray click must not be able to kill an app. The prompt
-- lives in the row's own label rather than a separate dialog, so the second
-- click lands exactly where the first one did.
local armed = nil  -- row index currently asking for confirmation
local arm_gen = 0  -- invalidates any pending auto-disarm timer

local confirm_width = 46

local function disarm()
  if armed and rows[armed] then
    rows[armed]:set({
      label = { drawing = false },
      icon = { width = popup_width - gutter }, -- give the name its space back
    })
  end
  armed = nil
  arm_gen = arm_gen + 1
end

local function arm(i)
  disarm()
  armed = i
  rows[i]:set({
    -- The row is a fixed popup_width, and the parts have explicit widths, so
    -- the prompt has to be taken OUT of the name's column rather than added
    -- beside it — otherwise the row measures wider than the popup it sits in.
    icon = { width = popup_width - gutter - confirm_width },
    label = {
      drawing = true,
      string = "quit?",
      align = "right",
      color = colors.red, -- the theme's alert tone
      font = { size = 10.5, style = settings.font.style_map["Bold"] },
      width = confirm_width,
      padding_right = inset,
    },
  })
  local gen = arm_gen
  -- Auto-disarm, so a row left armed cannot be confirmed by an unrelated click
  -- arriving much later.
  sbar.delay(4, function()
    if gen == arm_gen and armed == i then disarm() end
  end)
end

local function hide_popup()
  disarm()
  tray_bracket:set({ popup = { drawing = false } })
end

local function populate()
  local list = sbar.query("tray") or {}
  -- Rows are a reused pool, so a stale "quit?" would otherwise end up on
  -- whichever app happens to land on that index next.
  disarm()
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
      image = { string = entry.icon or "", desaturate = false },
      icon = { string = entry.name or "?", color = colors.white, width = popup_width - gutter },
      label = { drawing = false },
    })
  end
  for i = shown + 1, MAX_ROWS do rows[i]:set({ drawing = false }) end
  header:set({ label = { string = shown > 0 and (shown .. " items") or "none" } })
end

-- ── Interactions ───────────────────────────────────────────────────────────
for i = 1, MAX_ROWS do
  rows[i]:subscribe("mouse.clicked", function(env)
    local name = cache[i]
    if not name then return end
    -- sbar.tray() reaches the daemon directly. It replaced an
    -- sbar.exec("ybar --tray ...") that spent 35-55 ms per click spawning
    -- cmd.exe and then the CLI, to talk to the very process running this code.
    -- It also retires a quoting hazard: the name is a registry tooltip written
    -- by an arbitrary app, so building a shell command line out of it needed a
    -- metacharacter guard. Passed as an argument it is just a string.

    if not (env and env.BUTTON == "right") then
      -- LEFT-click opens: un-minimises the window the app already has, or
      -- starts it if it has none. This is the common action, so it gets the
      -- common button and happens on the first click.
      if armed == i then
        -- The row is asking "quit?" — a left click here means "no". Cancel and
        -- stop, rather than also opening: escaping the prompt is what the user
        -- is reaching for, and it keeps a mis-click from doing anything at all.
        disarm()
        return
      end
      disarm()
      hide_popup()
      sbar.tray(name, "invoke")
      return
    end

    -- RIGHT-click quits, and never on the first one.
    if armed ~= i then
      arm(i)
      return
    end
    disarm()
    sbar.tray(name, "close")

    -- Mark the row NOW. Without this the confirming click produced no visible
    -- change whatsoever: the app takes up to ~5s to go, so the row sat there
    -- looking unclicked — which is what makes a working close feel broken.
    --
    -- Greyed IN PLACE rather than hidden: removing it would shift every row
    -- below it up by one, and a quick follow-up click would then land on a
    -- different app than the one under the pointer a moment earlier. The
    -- reconcile below is what actually removes it, or restores it if the
    -- close failed.
    rows[i]:set({
      icon = { color = colors.grey },
      -- The app icon goes to luminance too, so the WHOLE row dims rather than
      -- a grey name sitting next to a full-colour logo. Needs the renderer's
      -- desaturate path: colour images are sampled straight off the colour
      -- atlas, so a tint has nowhere to apply without it.
      image = { desaturate = true },
    })
    cache[i] = nil -- further clicks on a closing row do nothing

    -- Reconcile repeatedly, and early. One late pass was useless in practice:
    -- moving the pointer off the popup fires mouse.exited.global, which hides
    -- it, and the pass was gated on the popup still being open — so the list
    -- only refreshed on the NEXT open, which is why closing the popup looked
    -- like a required step.
    for _, at in ipairs({ 1.5, 4, 7 }) do
      sbar.delay(at, function()
        if tray_bracket:query().popup.drawing == "on" then populate() end
      end)
    end
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
