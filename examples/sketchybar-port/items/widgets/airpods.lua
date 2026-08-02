local colors = require("colors")
local settings = require("settings")

-- AirPods pill: appears while AirPods are connected over Bluetooth; clicking
-- opens the stock macOS Sound menu (Control Center's Sound module) via the
-- soundmenu helper. Falls back to the Settings Sound pane when the stock
-- item cannot be located (module hidden / macOS changed its exposure).
local soundmenu_bin = SKETCHYBAR_CONFIG .. "/helpers/bin/soundmenu"
local blueutil_path = "/opt/homebrew/bin/blueutil"
if os.execute("test -x /opt/homebrew/bin/blueutil") == nil then
  blueutil_path = "/usr/local/bin/blueutil"
end

local airpods = sbar.add("item", "widgets.airpods", {
  position = "right",
  drawing = false,
  updates = true,
  update_freq = 5,
  image = { string = "sf.airpods.pro", size = 16, padding_left = 8, padding_right = 8 },
  icon = { drawing = false },
  label = { drawing = false },
  padding_left = 2,
  padding_right = 2,
  click_script = "'" .. soundmenu_bin:gsub("'", "'\\''")
    .. "' || open 'x-apple.systempreferences:com.apple.Sound-Settings.extension'",
})

local airpods_bracket = sbar.add("bracket", "widgets.airpods.bracket", { airpods.name }, {
  background = { color = colors.bg1 },
})

local airpods_padding = sbar.add("item", "widgets.airpods.padding", {
  position = "right",
  width = settings.group_paddings,
  drawing = false,
})

local function refresh()
  sbar.exec(blueutil_path .. " --connected 2>/dev/null", function(out)
    local connected = out:lower():find("airpods", 1, true) ~= nil
    airpods:set({ drawing = connected })
    airpods_padding:set({ drawing = connected })
  end)
end

airpods:subscribe({ "routine", "system_woke" }, refresh)
refresh()
