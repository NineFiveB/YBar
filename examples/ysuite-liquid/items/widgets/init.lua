-- Mock right cluster, left to right: CPU, Wi-Fi, Bluetooth, battery, clock.
-- Right-side items flow from the right edge, and calendar is required
-- before this file, so it stays the rightmost pill. Require order here is
-- therefore battery, bluetooth, wifi, cpu.
require("items.widgets.battery")
require("items.widgets.bluetooth")
require("items.widgets.wifi")
require("items.widgets.cpu")
