-- macOS integration helpers shared by the shipped themes (themes already
-- reach this tree for the compat shim). Everything here is optional sugar:
-- Settings deep links, scroll-to-adjust volume, charging-aware battery query.
local M = {}

M.SOUND_SETTINGS = "open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'"
M.BATTERY_SETTINGS = "open 'x-apple.systempreferences:com.apple.Battery-Settings.extension'"
M.WIFI_SETTINGS = "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'"
M.CALENDAR = "open -a Calendar"

-- Scroll on the item adjusts the output volume (4% per tick); the
-- volume_change event repaints the module.
function M.volume_scroll(item)
  item:subscribe("mouse.scrolled", function(env)
    local delta = tonumber(env.SCROLL_DELTA) or 0
    if delta == 0 then return end
    local step = delta > 0 and 4 or -4
    sbar.exec("osascript -e 'set volume output volume "
      .. "((output volume of (get volume settings)) + (" .. step .. "))'")
  end)
end

-- One pmset round-trip: callback(level, charging).
function M.battery(callback)
  sbar.exec("pmset -g batt | grep -Eo '[0-9]+%|AC Power' | tr '\\n' ' '", function(out)
    local level = tonumber((out or ""):match("(%d+)%%")) or 0
    callback(level, (out or ""):find("AC Power") ~= nil)
  end)
end

return M
