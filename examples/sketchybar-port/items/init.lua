-- ysuite-liquid has no Apple pill: its strip opens on the workspace row, and
-- the replica Apple menu duplicates a menu the system already puts one
-- keystroke away. The port and the glass themes keep it.
if not YSUITE_LIQUID then require("items.apple") end
require("items.menus")

-- Workspace pills: pick the adapter for the installed window manager.
--
-- Both adapters build a FIXED pill set at load and bind it to the live
-- workspaces from async queries with retries, so neither needs the WM to be
-- answering yet. That matters because YBar and the WM are both launchd
-- LaunchAgents with no start order between them (measured here: YBar
-- 13:34:59, AeroSpace 13:35:00), and the AeroSpace adapter used to create
-- one pill per name from a synchronous query at load — an empty answer meant
-- zero pills for the session, which this file papered over with a 30 s
-- readiness poll that also held front_app back. The pills now reveal on the
-- first query that answers, from the adapters' own startup retries or their
-- routine poll, and nothing here waits.
--
-- Load order is bar order within a position: front_app follows the pills
-- immediately so it sits at their right.
local function installed_at(name)
  for _, dir in ipairs({ "/opt/homebrew/bin/", "/usr/local/bin/" }) do
    if os.execute("test -x " .. dir .. name) == true then return dir .. name end
  end
  return nil
end
local has_aerospace = installed_at("aerospace") ~= nil
local has_yabai = installed_at("yabai") ~= nil

local use_yabai
if has_aerospace and has_yabai then
  -- Both installed: the one whose process is up, AeroSpace when both or
  -- neither are (the tie-break the old poll used). A process check is the
  -- right signal for a CHOICE, unlike for readiness — the adapters no longer
  -- need the server answering at load, only the right one to exist.
  use_yabai = os.execute("pgrep -xq yabai") == true
    and os.execute("pgrep -xq AeroSpace") ~= true
elseif has_yabai then
  use_yabai = true
else
  use_yabai = false   -- AeroSpace, or neither: that adapter idles quietly
end

if use_yabai then
  require("items.spaces_yabai")
else
  require("items.spaces")
end
require("items.front_app")

require("items.calendar")
require("items.widgets")
