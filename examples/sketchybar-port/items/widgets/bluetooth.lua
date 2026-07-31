local colors = require("colors")
local icons = require("icons")
local settings = require("settings")
local shell = require("helpers.shell")

local popup_width = 350

-- Resolve config dir for helper scripts
-- YBAR PORT: helpers live in the original sketchybar tree
local bt_script = SKETCHYBAR_CONFIG .. "/helpers/bluetooth_battery.sh"

-- Resolve blueutil path (Apple Silicon vs Intel)
local blueutil_path = "/opt/homebrew/bin/blueutil"
if os.execute("test -x /opt/homebrew/bin/blueutil") == nil then
  blueutil_path = "/usr/local/bin/blueutil"
end

-- ── SF Symbols for device types ─────────────────────────────────────────────
local type_icons = {
  headset  = "􀑈",  -- headphones
  keyboard = "􀇳",  -- keyboard
  trackpad = "􀟀",  -- rectangle.and.hand.point.up.left
  phone    = "􀟜",  -- iphone
  speaker  = "􀝎",  -- hifispeaker
  generic  = icons.bluetooth,
}

-- SF battery icons by charge level
local function battery_icon_for(pct)
  if pct >= 75 then return icons.battery._100
  elseif pct >= 50 then return icons.battery._75
  elseif pct >= 25 then return icons.battery._50
  elseif pct >= 10 then return icons.battery._25
  else return icons.battery._0
  end
end

local function battery_color_for(pct)
  if pct >= 50 then return colors.green
  elseif pct >= 20 then return colors.yellow
  else return colors.red
  end
end

-- ── Bar item: small bluetooth icon ──────────────────────────────────────────
local bt_icon = sbar.add("item", "widgets.bluetooth", {
  position = "right",
  icon = {
    string = icons.bluetooth,
    font = { style = settings.font.style_map["Regular"], size = 16.0 },
    color = colors.blue,
    width = 32,
    align = "center",
  },
  label = { drawing = false },
  padding_left = 4,
  padding_right = 4,
})

local bt_bracket = sbar.add("bracket", "widgets.bluetooth.bracket", { bt_icon.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", height = 30 },
})

sbar.add("item", "widgets.bluetooth.padding", {
  position = "right",
  width = settings.group_paddings,
})

local popup_pos = "popup." .. bt_bracket.name

-- ── Popup header ────────────────────────────────────────────────────────────
sbar.add("item", "widgets.bluetooth.popup.header", {
  position = popup_pos,
  width = popup_width,
  align = "center",
  icon = {
    string = icons.bluetooth,
    font = { style = settings.font.style_map["Bold"], size = 14.0 },
  },
  label = {
    string = "Bluetooth",
    font = { size = 15, style = settings.font.style_map["Bold"] },
  },
  background = { height = 2, color = colors.grey, y_offset = -15 },
  padding_left = 10,
  padding_right = 10,
  padding_bottom = 4,
})

-- ── Dynamic popup content ───────────────────────────────────────────────────
local function collapse_popup()
  bt_bracket:set({ popup = { drawing = false } })
  sbar.remove('/bt.device\\.*/')
end

local function build_popup()
  sbar.exec("'" .. bt_script:gsub("'", "'\\''") .. "' 2>/dev/null", function(output)
    -- Guard: don't add items if popup was closed while exec was running
    if bt_bracket:query().popup.drawing == "off" then return end

    if not output or output == "" then
      sbar.add("item", "bt.device.empty", {
        position = popup_pos,
        width = popup_width,
        align = "center",
        label = { string = "No paired devices", color = colors.grey },
        padding_top = 3,
        padding_bottom = 3,
      })
      return
    end

    local counter = 0
    for line in string.gmatch(output, "[^\n]+") do
      local name, address, connected_str, battery_str, dtype =
        line:match("^([^|]*)|([^|]*)|([01])|([^|]*)|([^|]*)$")

      if name and address then
        local is_connected = (connected_str == "1")
        local battery = tonumber(battery_str) or -1
        dtype = dtype or "generic"

        -- Device type icon
        local dev_icon = type_icons[dtype] or type_icons.generic

        -- Build label: battery info or connection state
        local label_str = ""
        local label_color = colors.grey

        if is_connected then
          label_color = colors.white
          if battery >= 0 then
            label_str = battery_icon_for(battery) .. " " .. battery .. "%"
            label_color = battery_color_for(battery)
          else
            label_str = "Connected"
          end
        else
          label_str = "Disconnected"
        end

        -- Connection dot
        local dot_color = is_connected and colors.green or colors.grey

        sbar.add("item", "bt.device." .. counter, {
          position = popup_pos,
          width = popup_width,
          icon = {
            string = dev_icon .. "  " .. name,
            color = is_connected and colors.white or colors.grey,
            font = { size = 12.0 },
            width = popup_width - 120,
            align = "left",
            padding_left = 10,
          },
          label = {
            string = label_str,
            color = label_color,
            font = {
              family = settings.font.numbers,
              style = settings.font.style_map["Bold"],
              size = 11.0,
            },
            width = 100,
            align = "right",
            padding_right = 10,
          },
          click_script = blueutil_path .. " "
            .. (is_connected and "--disconnect" or "--connect")
            .. " " .. shell.quote(address)
            .. " && sketchybar --trigger bt_refresh",
          padding_top = 4,
          padding_bottom = 4,
        })
        counter = counter + 1
      end
    end
  end)
end

local function toggle_popup()
  local should_draw = bt_bracket:query().popup.drawing == "off"
  if should_draw then
    bt_bracket:set({ popup = { drawing = true } })
    build_popup()
  else
    collapse_popup()
  end
end

-- ── Events ──────────────────────────────────────────────────────────────────
bt_icon:subscribe("mouse.clicked", toggle_popup)
bt_icon:subscribe("mouse.exited.global", collapse_popup)

-- Custom event for refreshing after connect/disconnect
sbar.add("event", "bt_refresh")
bt_icon:subscribe("bt_refresh", function()
  -- Rebuild popup if it's open
  local drawing = bt_bracket:query().popup.drawing == "on"
  if drawing then
    sbar.remove('/bt.device\\.*/')
    build_popup()
  end
end)
