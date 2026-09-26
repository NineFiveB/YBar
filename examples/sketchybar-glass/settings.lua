-- Glass-theme settings: the port's values with tightened spacing.
return {
  -- Bar pill height (see the port's settings.lua).
  -- Ink width of the widest single-character workspace mark, in the numbers
  -- face at the default icon size. The marks are set proportionally, so a "1"
  -- pill measured 3pt narrower than a "3" and the strip read uneven; pinning
  -- the icon column to the widest mark makes every pill the same width.
  -- Measured here: "1" 5pt, most digits 8pt, "W" 13pt — and 8 is only the ink,
  -- so a wide letter still centres in the padded column without clipping.
  workspace_mark_width = 8,
  pill_height = 28,
  paddings = 3,        -- inner icon/label padding (breathing room inside pills)
  group_paddings = 2,  -- was 5: spacer items between widget groups

  icons = "sf-symbols",
  font = require("helpers.default_font"),
}
