return {
  -- Bar pill height. Workspace pills sit 2pt inside it and their focus
  -- ring takes the full height, so this one number sizes the whole strip.
  -- Ink width of the widest single-character workspace mark, in the numbers
  -- face at the default icon size. The marks are set proportionally, so a "1"
  -- pill measured 3pt narrower than a "3" and the strip read uneven; pinning
  -- the icon column to the widest mark makes every pill the same width.
  -- Measured here: "1" 5pt, most digits 8pt, "W" 13pt — and 8 is only the ink,
  -- so a wide letter still centres in the padded column without clipping.
  workspace_mark_width = 8,
  pill_height = 28,
  paddings = 3,
  group_paddings = 5,
  -- ysuite-liquid: seconds before workspace pills drop app icons.
  -- The active pill then shows the front app name; the others keep their number.
  workspace_icon_hide = 2.8,

  icons = "sf-symbols", -- alternatively available: NerdFont

  -- This is a font configuration for SF Pro and SF Mono (installed manually)
  font = require("helpers.default_font"),

  -- Alternatively, this is a font config for JetBrainsMono Nerd Font
  -- font = {
  --   text = "JetBrainsMono Nerd Font", -- Used for text
  --   numbers = "JetBrainsMono Nerd Font", -- Used for numbers
  --   style_map = {
  --     ["Regular"] = "Regular",
  --     ["Semibold"] = "Medium",
  --     ["Bold"] = "SemiBold",
  --     ["Heavy"] = "Bold",
  --     ["Black"] = "ExtraBold",
  --   },
  -- },
}
