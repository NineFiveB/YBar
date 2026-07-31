require("items.apple")
require("items.menus")
require("items.spaces")
require("items.front_app")
require("items.calendar")
require("items.widgets")

-- YBAR PORT: the media widget is not ported — it depends on the media_change
-- event (private MediaRemote framework, entitlement-locked since macOS 15.3).
-- When YBar ships its platform-binary now-playing adapter, port items/media.lua
-- on top of it.
-- require("items.media")
