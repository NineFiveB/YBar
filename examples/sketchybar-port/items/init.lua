require("items.apple")
require("items.menus")

-- Workspace pills: load the yabai or AeroSpace adapter only once that window
-- manager ANSWERS — and wait instead of guessing when nothing answers yet.
--
-- YBar and the window manager are both launchd LaunchAgents, and launchd
-- guarantees no start order between them. Measured on this machine: YBar
-- started at 13:34:59 and AeroSpace at 13:35:00. That one second is fatal,
-- because items/spaces.lua discovers AeroSpace's workspace NAMES with a
-- single synchronous query at config load and creates one pill per name —
-- an empty answer creates zero pills, permanently. Its own retry loop only
-- toggles the visibility of pills that already exist, so it can never
-- recover. Result: a blank workspace strip until a manual YBar restart.
--
-- Readiness therefore means "the CLI returns a workspace list", NOT "the
-- process exists" — pgrep was the bug, since AeroSpace's process is up a
-- beat before its server accepts queries. Selection rules:
--
--   * whichever WM answers now -> its adapter immediately (AeroSpace wins if
--     both answer, as before). This is the common path and costs one cheap
--     subprocess; a WM that is down fails the probe instantly rather than
--     hanging.
--   * installed but not answering yet -> poll below until one answers, then
--     load. This is the launchd race, and covers a single installed WM just
--     as much as both: spaces.lua needs a live server at creation time.
--   * neither installed -> the AeroSpace adapter, which idles quietly on
--     empty query results (unchanged fallback).
--
-- (items/spaces_yabai.lua creates a fixed pill set and needs no live server
-- to build it, but it is gated the same way so the two adapters behave
-- identically.)

local function installed_at(name)
  for _, dir in ipairs({ "/opt/homebrew/bin/", "/usr/local/bin/" }) do
    if os.execute("test -x " .. dir .. name) == true then return dir .. name end
  end
  return nil
end
local AEROSPACE_BIN = installed_at("aerospace")
local YABAI_BIN = installed_at("yabai")

-- The probe is the adapter's own first query, so "ready" here means exactly
-- what the adapter needs a moment later.
local AEROSPACE_PROBE = AEROSPACE_BIN
    and (AEROSPACE_BIN .. " list-workspaces --all") or nil
local YABAI_PROBE = YABAI_BIN and (YABAI_BIN .. " -m query --spaces") or nil

local function answers(probe)
  return probe ~= nil and os.execute(probe .. " >/dev/null 2>&1") == true
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

if answers(AEROSPACE_PROBE) then
  load_adapter(false)
elseif answers(YABAI_PROBE) then
  load_adapter(true)
elseif AEROSPACE_BIN == nil and YABAI_BIN == nil then
  load_adapter(false)   -- neither installed: unchanged AeroSpace fallback
else
  -- Installed but not answering yet: the launchd race. Poll until one WM's
  -- CLI responds. Each attempt is a single async exec — the 2s wait AND the
  -- probes both live in the child shell (same cadence as the adapters' own
  -- startup retries) because the Lua runtime runs on the daemon's main
  -- thread: an os.execute sleep here would stall rendering. Bounded so the
  -- config still finishes deterministically on a machine where the WM is
  -- installed but never started: after MAX_POLLS the AeroSpace fallback
  -- loads. The bound is generous (~30s) on purpose — giving up early means
  -- a permanently blank workspace strip, while polling longer only delays
  -- front_app on a login where no WM is coming up anyway.
  local MAX_POLLS = 15
  local PROBE = "sleep 2"
      .. (AEROSPACE_PROBE and ("; " .. AEROSPACE_PROBE
            .. " >/dev/null 2>&1 && echo AeroSpace") or "")
      .. (YABAI_PROBE and ("; " .. YABAI_PROBE
            .. " >/dev/null 2>&1 && echo yabai") or "")
  local poll
  poll = function(attempt)
    sbar.exec(PROBE, function(out)
      if adapter_loaded then return end
      if out:find("AeroSpace") then   -- both answering: AeroSpace wins
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
