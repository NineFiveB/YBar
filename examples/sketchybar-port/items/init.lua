require("items.apple")
require("items.menus")

-- Workspace pills: pick the yabai or AeroSpace adapter by what is actually
-- RUNNING — and when that can't be known yet, wait instead of guessing.
--
-- YBar and the window manager are both launchd LaunchAgents, and launchd
-- guarantees no start order between them. A one-shot check at config load
-- therefore races: when YBar wins, neither WM answers pgrep yet, and the old
-- "fall back to whichever is installed" tiebreak picked the AeroSpace
-- adapter on any machine with both installed (a real, common case — e.g.
-- trying yabai without uninstalling AeroSpace first). AeroSpace never came
-- up, so the bar showed zero workspace pills permanently, until a manual
-- YBar restart — even though yabai was live seconds later. Selection rules:
--
--   * exactly one WM installed -> its adapter, unconditionally. Each adapter
--     already retries internally while its WM is installed but not answering
--     yet, so "installed but still starting" needs no handling here.
--   * both installed -> whichever is RUNNING (AeroSpace wins the
--     both-running tie, as before). Neither running yet — the launchd
--     race — defers the choice: poll below until one appears.
--   * neither installed -> the AeroSpace adapter, which idles quietly on
--     empty query results (unchanged fallback).

local function running(process_name)
  return os.execute("pgrep -x " .. process_name .. " >/dev/null 2>&1") == true
end
local function installed(name)
  return os.execute("test -x /opt/homebrew/bin/" .. name) == true
      or os.execute("test -x /usr/local/bin/" .. name) == true
end

-- Exactly-once loader. require() itself caches, but the guard is what keeps
-- a late poll callback from re-adding front_app or re-running an adapter's
-- side effects. front_app rides along because bar order is creation order
-- within a position: it must be created after the pills to sit at their
-- right, so a deferred adapter defers it too. calendar/widgets keep their
-- order on the bar's right side — an independent stack — so they load on
-- time (bottom of this file) even while the adapter choice is pending.
local adapter_loaded = false
local function load_adapter(use_yabai)
  if adapter_loaded then return end
  adapter_loaded = true
  if use_yabai then
    require("items.spaces_yabai")
  else
    require("items.spaces")
  end
  require("items.front_app")
end

local have_yabai = installed("yabai")
local have_aerospace = installed("aerospace")

if have_yabai and not have_aerospace then
  load_adapter(true)
elseif have_aerospace and not have_yabai then
  load_adapter(false)
elseif running("AeroSpace") then
  load_adapter(false)
elseif running("yabai") then
  load_adapter(true)
elseif not have_yabai then
  load_adapter(false)   -- neither installed: unchanged AeroSpace fallback
else
  -- Both installed, neither running: the launchd race. Poll until one WM
  -- appears. Each attempt is a single async exec — the 2s wait AND the
  -- pgrep probe both live in the child shell (same cadence as the adapters'
  -- own startup retries) because the Lua runtime runs on the daemon's main
  -- thread: an os.execute sleep here would stall rendering. Bounded so the
  -- config still finishes deterministically on a machine where neither
  -- service ever starts: after MAX_POLLS the old AeroSpace fallback loads.
  -- The bound is generous (~30s) on purpose — committing wrong is permanent
  -- broken pills, while polling a little longer only delays front_app on an
  -- already-WM-less login.
  local MAX_POLLS = 15
  local PROBE = "sleep 2;"
      .. " pgrep -x AeroSpace >/dev/null 2>&1 && echo AeroSpace;"
      .. " pgrep -x yabai >/dev/null 2>&1 && echo yabai"
  local poll
  poll = function(attempt)
    sbar.exec(PROBE, function(out)
      if adapter_loaded then return end
      if out:find("AeroSpace") then   -- both up: AeroSpace wins, as before
        load_adapter(false)
      elseif out:find("yabai") then
        load_adapter(true)
      elseif attempt < MAX_POLLS then
        poll(attempt + 1)
      else
        load_adapter(false)
      end
    end)
  end
  poll(1)
end

require("items.calendar")
require("items.widgets")
