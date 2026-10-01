-- The theme's layout and font knobs. Declared rather than hard-coded so a
-- settings app can change them (docs/CONFIG.md, "Settings a GUI can
-- reach"); the shape returned is the one the port's item files read.
local tunable = require("helpers.tunable")

local S = tunable({
  -- Bar pill height (see the port's settings.lua).
  { key = "pill_height", type = "number", default = 32, min = 20, max = 60,
    label = "Pill height", section = "Layout" },
  { key = "paddings", type = "number", default = 5, min = 0, max = 20,
    label = "Padding around icons and labels", section = "Layout" },
  { key = "group_paddings", type = "number", default = 4, min = 0, max = 20,
    label = "Gap between pills", section = "Layout" },
  -- Ink width of the widest single-character workspace mark, in the numbers
  -- face at the default icon size. The marks are set proportionally, so a "1"
  -- pill measured 3pt narrower than a "3" and the strip read uneven; pinning
  -- the icon column to the widest mark makes every pill the same width.
  -- Measured here: "1" 5pt, most digits 8pt, "W" 13pt — and 8 is only the ink,
  -- so a wide letter still centres in the padded column without clipping.
  { key = "workspace_mark_width", type = "number", default = 8, min = 4, max = 20,
    label = "Workspace mark column width", section = "Workspaces" },
  -- Seconds before workspace pills drop app icons.
  { key = "workspace_icon_hide", type = "number", default = 2.8, min = 0, max = 60,
    label = "Seconds before workspace pills drop app icons", section = "Workspaces" },
  { key = "icons", type = "enum", default = "sf-symbols", options = { "sf-symbols", "NerdFont" },
    label = "Icon set", section = "Fonts" },
  -- Empty family resolves to NSFont.systemFont, the Mac UI font.
  { key = "font.text", type = "string", default = "",
    label = "Text font (empty for the system font)", section = "Fonts" },
  { key = "font.numbers", type = "string", default = "",
    label = "Numbers font (empty for the system font)", section = "Fonts" },
})

local font = require("helpers.default_font")
font.text = S.font.text
font.numbers = S.font.numbers

return {
  workspace_mark_width = S.workspace_mark_width,
  pill_height = S.pill_height,
  paddings = S.paddings,
  group_paddings = S.group_paddings,
  workspace_icon_hide = S.workspace_icon_hide,
  icons = S.icons,
  font = font,
}
