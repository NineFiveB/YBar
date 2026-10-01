-- Right cluster, left to right: tray, CPU, Wi-Fi, Bluetooth, battery, clock.
-- Right-side items flow from the right edge, and calendar is required
-- before this file, so it stays the rightmost pill. Require order here is
-- therefore battery, bluetooth, wifi, cpu, menubar — the order a settings
-- app can rearrange, with a switch per widget.
local W = require("helpers.tunable")({
  { key = "widgets.order", type = "list",
    default = { "battery", "bluetooth", "wifi", "cpu", "menubar" },
    label = "Order, from the clock outward", section = "Widgets" },
  { key = "widgets.battery", type = "bool", default = true, label = "Battery", section = "Widgets" },
  { key = "widgets.bluetooth", type = "bool", default = true, label = "Bluetooth", section = "Widgets" },
  { key = "widgets.wifi", type = "bool", default = true, label = "Wi-Fi", section = "Widgets" },
  { key = "widgets.cpu", type = "bool", default = true, label = "System monitor", section = "Widgets" },
  -- The tray: the background apps' own menu bar items (OneDrive, Proton,
  -- Creative Cloud), collapsed behind a chevron, with their real menus
  -- reachable even while the native bar is covered. Needs the port's
  -- statusitems helper, which `make helpers` builds.
  { key = "widgets.menubar", type = "bool", default = true, label = "Tray", section = "Widgets" },
}).widgets

local known = { "battery", "bluetooth", "wifi", "cpu", "menubar" }
local order, seen = {}, {}
for _, name in ipairs(W.order) do
  local ok = false
  for _, k in ipairs(known) do if k == name then ok = true end end
  if not ok then
    io.stderr:write("[ysuite-liquid] widgets.order: no widget named " .. name .. "\n")
  elseif not seen[name] then
    seen[name] = true
    order[#order + 1] = name
  end
end
-- A widget left out of the list is still a widget; only its switch hides it.
for _, name in ipairs(known) do
  if not seen[name] then order[#order + 1] = name end
end

for _, name in ipairs(order) do
  if W[name] ~= false then require("items.widgets." .. name) end
end
