-- Windows integration helpers shared by the theme (the analog of the macOS
-- tree's helpers/mac.lua). Everything here is optional sugar: Settings deep
-- links, scroll-to-adjust volume, a battery snapshot query.
local M = {}

M.SOUND_SETTINGS = 'explorer.exe "ms-settings:sound"'
M.BATTERY_SETTINGS = 'explorer.exe "ms-settings:batterysaver"'
M.WIFI_SETTINGS = 'explorer.exe "ms-settings:network-wifi"'
M.BLUETOOTH_SETTINGS = 'explorer.exe "ms-settings:bluetooth"'
M.CALENDAR = "explorer.exe outlookcal:"

-- Scroll on the item adjusts the output volume (2% per synthetic key tick,
-- two ticks per scroll notch = 4%); the native volume_change event repaints
-- the module — no polling.
function M.volume_scroll(item)
  item:subscribe("mouse.scrolled", function(env)
    local delta = tonumber(env.SCROLL_DELTA) or 0
    if delta == 0 then return end
    local key = delta > 0 and 175 or 174 -- VK volume up / down
    sbar.exec("powershell.exe -NoProfile -Command "
      .. '"$w=New-Object -ComObject WScript.Shell; 1..2 | % { $w.SendKeys([char]'
      .. key .. ') }"')
  end)
end

-- One WMI round-trip: callback(level, charging). BatteryStatus 2/6/7/8/9
-- all mean external power is present.
function M.battery(callback)
  sbar.exec("powershell.exe -NoProfile -Command "
    .. '"$b = Get-CimInstance Win32_Battery | Select-Object -First 1; '
    .. "if ($b) { Write-Output ($b.EstimatedChargeRemaining.ToString() + '|' + $b.BatteryStatus) } "
    .. 'else { Write-Output \'0|2\' }"', function(out)
    local level, status = (out or ""):match("(%d+)|(%d+)")
    local charging = false
    if status then
      local s = tonumber(status)
      charging = s == 2 or s == 6 or s == 7 or s == 8 or s == 9
    end
    callback(tonumber(level) or 0, charging)
  end)
end

return M
