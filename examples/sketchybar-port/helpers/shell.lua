-- config/helpers/shell.lua
-- Shell-safe quoting for interpolating values into shell commands
local M = {}

--- Wraps a string in single quotes, escaping any embedded single quotes.
-- e.g., "it's here" → "'it'\''s here'"
function M.quote(s)
  if s == nil then return "''" end
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

return M
