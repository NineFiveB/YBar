-- widgets/menubar.lua (status-item capture), altserver.lua, claude.lua and
-- skhd_mode.lua are macOS-only and not ported (spec 10.6 / PORTING-WIN.md).
require("items.widgets.apps")
require("items.widgets.battery")
require("items.widgets.bluetooth")
require("items.widgets.wifi")
require("items.widgets.cpu")
require("items.widgets.media")
