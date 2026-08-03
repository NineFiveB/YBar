require("items.apple")
require("items.menus")

-- Workspace pills: AeroSpace wins when both tilers are installed; a lone
-- yabai install drives native Spaces via the builtin space_change event.
-- Neither installed falls back to the AeroSpace module, which idles quietly
-- on empty query results.
local function installed(name)
  return os.execute("test -x /opt/homebrew/bin/" .. name) == true
      or os.execute("test -x /usr/local/bin/" .. name) == true
end
if installed("yabai") and not installed("aerospace") then
  require("items.spaces_yabai")
else
  require("items.spaces")
end
require("items.front_app")
require("items.calendar")
require("items.widgets")

-- YBAR PORT: the media widget is not ported — it depends on the media_change
-- event (private MediaRemote framework, entitlement-locked since macOS 15.3).
-- When YBar ships its platform-binary now-playing adapter, port items/media.lua
-- on top of it.
-- require("items.media")
