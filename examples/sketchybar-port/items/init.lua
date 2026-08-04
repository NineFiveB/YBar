require("items.apple")
require("items.menus")

-- Workspace pills: pick whichever tiler is actually RUNNING, not just
-- installed. Binary presence alone is the wrong signal once a machine has
-- both installed (a real, common case — e.g. trying yabai without
-- uninstalling AeroSpace first): AeroSpace's own adapter queries its CLI
-- synchronously at config load and creates zero pills if the app isn't
-- live, even though the aerospace binary is sitting right there.
-- Neither running (e.g. fresh boot, before login items launch) falls back
-- to binary presence, then to the AeroSpace module, which idles quietly on
-- empty query results until the app appears.
local function running(process_name)
  return os.execute("pgrep -x " .. process_name .. " >/dev/null 2>&1") == true
end
local function installed(name)
  return os.execute("test -x /opt/homebrew/bin/" .. name) == true
      or os.execute("test -x /usr/local/bin/" .. name) == true
end

local use_yabai
if running("yabai") and not running("AeroSpace") then
  use_yabai = true
elseif running("AeroSpace") then
  use_yabai = false
else
  use_yabai = installed("yabai") and not installed("aerospace")
end

if use_yabai then
  require("items.spaces_yabai")
else
  require("items.spaces")
end
require("items.front_app")
require("items.calendar")
require("items.widgets")
