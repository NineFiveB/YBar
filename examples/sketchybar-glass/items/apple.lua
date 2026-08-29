local colors = require("colors")
local icons = require("icons")
local settings = require("settings")

-- YBAR PORT (Windows): replica of the macOS 26 Apple menu, recast as a
-- Windows menu (left click); right click pops the real Start menu via
-- Win-key synthesis. Restart/Shut Down confirm with a second click — the
-- scripted `shutdown` actions bypass Windows' own dialogs.
-- Dropped vs macOS: App Store row (no analog), "Force Quit <front app>"
-- live tracking (Task Manager row is static), and "Log Out <name>" (the
-- `id -F` full-name lookup is macOS-only).

local popup_width = 211
local inset = 11

-- Padding item required because of bracket
sbar.add("item", { width = 4 })

local apple = sbar.add("item", {
  icon = {
    font = { size = 14 },
    string = icons.apple, -- resolves to "sf:apps" (Fluent ViewAll grid) on Windows
    padding_right = 7,
    padding_left = 7,
  },
  label = { drawing = false },
  background = {
    color = colors.bg2,
    border_color = colors.black,
    border_width = 1
  },
  padding_left = 1,
  padding_right = 1,
})

-- Double border for apple using a single item bracket
local apple_bracket = sbar.add("bracket", { apple.name }, {
  background = {
    color = colors.transparent,
    height = 26,
    border_color = colors.grey,
  },
  popup = { align = "left" }
})

-- Padding item required because of bracket
sbar.add("item", { width = 6 })

local popup_pos = "popup." .. apple_bracket.name

local function hide_popup()
  apple_bracket:set({ popup = { drawing = false } })
end

local function add_separator()
  sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    icon = { drawing = false },
    label = { drawing = false },
    background = { height = 2, color = colors.with_alpha(colors.grey, 0.3) },
  })
end

local rows = {}          -- item handle -> definition
local confirm_armed = {} -- item handle -> true while awaiting second click

-- Native anatomy: optional leading Fluent glyph, title, optional right-aligned
-- shortcut hint (grey) or submenu chevron. Glyphless titles start at the
-- left margin, exactly like the real menu.
local function add_row(title, action, opts)
  opts = opts or {}
  local right = opts.shortcut or opts.chevron
  local row = sbar.add("item", {
    position = popup_pos,
    width = popup_width,
    align = "left",
    image = {
      string = opts.glyph or "",
      size = 16,
      padding_left = inset,
      padding_right = 7,
    },
    icon = {
      string = title,
      align = "left",
      color = colors.white,
      font = { size = 11.5 },
      padding_left = opts.glyph and 0 or inset,
      width = popup_width - 69 - (opts.glyph and (inset + 21) or inset),
    },
    label = right and {
      string = right,
      align = "right",
      color = colors.with_alpha(colors.grey, 0.9),
      font = { size = 10.5 },
      width = 69,
      padding_right = inset,
    } or { drawing = false },
  })
  rows[row] = { title = title, action = action, confirm = opts.confirm }
  row:subscribe("mouse.clicked", function()
    local def = rows[row]
    if def.confirm and not confirm_armed[row] then
      confirm_armed[row] = true
      row:set({ icon = { string = def.title .. " — confirm" } })
      return
    end
    confirm_armed[row] = nil
    row:set({ icon = { string = def.title } })
    hide_popup()
    sbar.exec(def.action)
  end)
  return row
end

local function reset_confirms()
  for row, def in pairs(rows) do
    if confirm_armed[row] then
      confirm_armed[row] = nil
      row:set({ icon = { string = def.title } })
    end
  end
end

add_row("About This PC",
  [[explorer.exe "ms-settings:about"]],
  { glyph = "sf.desktopcomputer" }) -- laptopcomputer has no Fluent mapping
add_separator()
add_row("System Settings", "explorer.exe ms-settings:",
  { glyph = "sf.gearshape" })
add_separator()
-- Task Manager stands in for the macOS Force Quit row. Its real shortcut
-- (Ctrl+Shift+Esc) does not fit the 78 px hint column, so no hint here.
add_row("Task Manager", "taskmgr.exe")
add_separator()
-- shutdown.exe takes dash-form switches too; the dash form dodges the
-- MSYS sh path mangling that would eat `/r` and `/s`.
add_row("Lock", "rundll32.exe user32.dll,LockWorkStation",
  { shortcut = "Win+L" })
add_row("Sleep", "rundll32.exe powrprof.dll,SetSuspendState 0,1,0")
add_row("Restart", "shutdown.exe -r -t 0", { confirm = true })
add_row("Shut Down", "shutdown.exe -s -t 0", { confirm = true })

local function toggle_popup(env)
  if env.BUTTON == "right" then
    -- The real Start menu, via Win-key synthesis (Ctrl+Esc).
    sbar.exec("powershell.exe -NoProfile -Command '$w=New-Object -ComObject WScript.Shell; $w.SendKeys(\"^{ESC}\")'")
    return
  end
  local should_draw = apple_bracket:query().popup.drawing == "off"
  if should_draw then
    reset_confirms()
    apple_bracket:set({ popup = { drawing = true } })
  else
    hide_popup()
  end
end

apple:subscribe("mouse.clicked", toggle_popup)
apple:subscribe("mouse.exited.global", function()
  reset_confirms()
  hide_popup()
end)
