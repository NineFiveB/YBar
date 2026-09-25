-- Right cluster, left to right: tray, CPU, Wi-Fi, Bluetooth, battery, clock.
-- Right-side items flow from the right edge, and calendar is required
-- before this file, so it stays the rightmost pill. Require order here is
-- therefore battery, bluetooth, wifi, cpu, menubar.
require("items.widgets.battery")
require("items.widgets.bluetooth")
require("items.widgets.wifi")
require("items.widgets.cpu")
-- The tray: the background apps' own menu bar items (OneDrive, Proton,
-- Creative Cloud), collapsed behind a chevron, with their real menus
-- reachable even while the native bar is covered. Needs the port's
-- statusitems helper, which `make helpers` builds.
require("items.widgets.menubar")
