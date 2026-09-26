local colors = require("colors")

-- A rule between popup sections. It has to opt out of the glass treatment the
-- liquid themes give every other background: the rim light, the sheen and a
-- 20 pt corner radius all landing on a two-pixel strip turn a grey hairline
-- into a bright white bar. Flat, one point tall, no radius — a rule again.
local M = {}

M.color = colors.with_alpha(colors.grey, 0.45)

-- extra merges on top, for the header underline's y_offset or a hidden rule.
function M.background(extra)
  local bg = {
    height = 1,
    corner_radius = 0,
    color = M.color,
    glass = false,
    sheen = false,
    border_width = 0,
  }
  for key, value in pairs(extra or {}) do bg[key] = value end
  return bg
end

return M
