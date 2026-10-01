-- Declare the knobs a settings app may change, and read the merged values
-- back (the user's overrides over the defaults, nested by dotted key). On an
-- engine without `ybar.settings` the defaults come back as-is, so the theme
-- still loads on a daemon older than the settings layer.
local function defaults(list)
  local out = {}
  for _, entry in ipairs(list) do
    local parts = {}
    for segment in entry.key:gmatch("[^.]+") do parts[#parts + 1] = segment end
    local node = out
    for i = 1, #parts - 1 do
      node[parts[i]] = node[parts[i]] or {}
      node = node[parts[i]]
    end
    node[parts[#parts]] = entry.default
  end
  return out
end

return function(list)
  if ybar and ybar.settings then return ybar.settings(list) end
  return defaults(list)
end
