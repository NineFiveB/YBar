-- Item load order = bar order within each position. The macOS tree runs a
-- WM-readiness poll here (the launchd race between YBar and AeroSpace);
-- Windows needs none of it: the komorebi adapter is event-driven — the
-- daemon owns komorebi detection, re-attaches when komorebi starts late,
-- and replays state on attach, so the pill strip populates whenever
-- komorebi answers, with no probing at config load.
--
-- items/menus.lua (the macOS app-menu swap) has no Windows concept and is
-- not ported. The system-menu pill (items/apple.lua) is not loaded either:
-- a launcher like Raycast covers everything it offered — uncomment the
-- require to bring it back.
-- require("items.apple")
require("items.spaces")
-- items/front_app.lua is not loaded: the focused app's name earns no room on
-- the strip, and the macOS click-through to that app's menu titles has no
-- Windows equivalent, so the label was inert. Uncomment to bring it back.
-- require("items.front_app")
require("items.calendar")
require("items.widgets")
