local colors = require("colors")
local settings = require("settings")
local shell = require("helpers.shell")
local rule = require("helpers.separator")

-- Liquid Glass Bluetooth popup: device name, then a scan section with Pair.
-- Paired devices show a gray Connect capsule only while the pointer is on
-- that row. A connected device always shows Disconnect, which turns red
-- while it runs.

local popup_width = 280
local inset = 12
local max_devices = 6
local button_width = 108
local blue = 0x990a84ff
local disconnect_bg = colors.button
local disconnect_red = 0xccff453a
local row_active = colors.selection

local bt_script = SKETCHYBAR_CONFIG .. "/helpers/bluetooth_battery.sh"
local blueutil_path = "/opt/homebrew/bin/blueutil"
if os.execute("test -x /opt/homebrew/bin/blueutil") == nil then
  blueutil_path = "/usr/local/bin/blueutil"
end
local function blueutil(args)
  return blueutil_path .. " " .. args
end

local bt_icon = sbar.add("item", "widgets.bluetooth", {
  position = "right",
  icon = {
    string = "\u{F00AF}",
    font = { family = "Symbols Nerd Font", size = 15.0 },
    color = colors.white,
    padding_left = 8,
    padding_right = 8,
  },
  label = { drawing = false },
})

local bt_bracket = sbar.add("bracket", "widgets.bluetooth.bracket", { bt_icon.name }, {
  background = { color = colors.bg1 },
  popup = { align = "center", wrap_width = popup_width },
})

require("helpers.hover").pill(bt_bracket, bt_icon)

local popup_pos = "popup." .. bt_bracket.name

local header = sbar.add("item", "widgets.bluetooth.popup.header", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "Bluetooth",
    align = "left",
    font = { size = 14, style = settings.font.style_map["Regular"] },
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
})

local function action_label(text, bg, use_glass)
  return {
    string = text,
    drawing = true,
    align = "right",
    color = colors.white,
    font = { size = 12, style = settings.font.style_map["Regular"] },
    width = button_width,
    padding_right = 10,
    background = {
      color = bg,
      height = 24,
      corner_radius = 12,
      drawing = true,
      -- A glass chip on this plate was covering the device name.
      glass = use_glass == true,
      sheen = false,
      padding_left = 10,
      padding_right = 10,
    },
  }
end

-- The row is a fixed width. The name uses all of it until a button is
-- showing, then it gives that slot up so the capsule is not clipped off.
-- A glyph column ahead of the name. The popup wraps at popup_width, so the
-- glyph and the row have to sum to it or the row drops onto its own line.
local icon_width = 26
local row_width = popup_width - 16 - icon_width
local name_width = popup_width - 32 - icon_width
local name_width_with_button = popup_width - 24 - button_width - icon_width

-- blueutil reports no device class, so the name is the only signal. Plain
-- substring matches, longest first; anything unrecognised keeps the generic
-- radio glyph rather than guessing.
local function device_symbol(name)
  local n = (name or ""):lower()
  local function has(s) return n:find(s, 1, true) ~= nil end
  if has("airpods max") then return "sf:airpodsmax" end
  if has("airpods pro") then return "sf:airpods.pro" end
  if has("airpod") then return "sf:airpods" end
  if has("beats") or has("buds") or has("headphone") or has("earbud") then
    return "sf:beats.headphones"
  end
  if has("trackpad") then return "sf:rectangle.and.hand.point.up.left" end
  if has("keyboard") then return "sf:keyboard" end
  if has("mouse") then return "sf:magicmouse" end
  if has("iphone") then return "sf:iphone" end
  if has("ipad") then return "sf:ipad" end
  if has("watch") then return "sf:applewatch" end
  if has("apple tv") or has(" tv") or n == "tv" then return "sf:appletv" end
  if has("macbook") or has("imac") or has("mac ") then return "sf:laptopcomputer" end
  if has("homepod") or has("speaker") then return "sf:homepod" end
  if has("controller") or has("gamepad") then return "sf:gamecontroller" end
  if has("printer") then return "sf:printer" end
  if has("pencil") then return "sf:applepencil" end
  return "sf:dot.radiowaves.left.and.right"
end

local function glyph_piece()
  return {
    position = popup_pos,
    drawing = false,
    width = icon_width,
    icon = {
      string = "",
      align = "center",
      color = colors.with_alpha(colors.white, 0.75),
      font = { size = 13 },
      width = icon_width,
    },
    label = { drawing = false },
    padding_left = 8,
    padding_right = 0,
  }
end

local paired_glyphs = {}
local nearby_glyphs = {}
local paired_rows = {}
for i = 1, max_devices do
  paired_glyphs[i] = sbar.add("item", "widgets.bluetooth.dev." .. i .. ".icon", glyph_piece())
  paired_rows[i] = sbar.add("item", "widgets.bluetooth.dev." .. i, {
    position = popup_pos,
    drawing = false,
    width = row_width,
    align = "left",
    background = {
      height = 36,
      corner_radius = 12,
      color = colors.transparent,
      drawing = true,
      glass = false,
      sheen = false,
    },
    icon = {
      string = "",
      align = "left",
      color = colors.white,
      font = { size = 13 },
      width = name_width,
      -- A name longer than the slot ramps out under the button instead of
      -- being cut mid-letter.
      fade_width = 18,
      padding_left = 2,
    },
    label = { drawing = false },
    padding_left = 0,
    padding_right = 8,
  })
end

local scan_label = sbar.add("item", "widgets.bluetooth.scan", {
  position = popup_pos,
  width = popup_width,
  icon = {
    string = "Looking for devices…",
    align = "left",
    color = colors.with_alpha(colors.white, 0.62),
    font = { size = 12 },
    width = popup_width,
    padding_left = inset,
  },
  label = { drawing = false },
  background = rule.background({ y_offset = 12 }),
})

local spinner = require("helpers.spinner").attach(scan_label, {
  size = 10, align = "l", padding_left = inset,
})

local nearby_rows = {}
for i = 1, max_devices do
  nearby_glyphs[i] = sbar.add("item", "widgets.bluetooth.near." .. i .. ".icon", glyph_piece())
  nearby_rows[i] = sbar.add("item", "widgets.bluetooth.near." .. i, {
    position = popup_pos,
    drawing = false,
    width = row_width,
    icon = {
      string = "",
      align = "left",
      color = colors.with_alpha(colors.white, 0.8),
      font = { size = 13 },
      width = row_width - button_width - 8,
      fade_width = 18,
      padding_left = 2,
    },
    label = action_label("Pair", blue, true),
    padding_left = 0,
    padding_right = 8,
  })
end

local paired_cache = {}
local nearby_cache = {}
local bt_power = true
local busy = false
local pressed_row = nil
-- Address of the disconnected row under the pointer. Connect is drawn only
-- for that device, so a refresh cannot stick the button on a neighbor.
local hovered_address = nil

local function paint_paired()
  local show = bt_power
  for i = 1, max_devices do
    local dev = show and paired_cache[i] or nil
    if dev then
      paired_glyphs[i]:set({
        drawing = true,
        icon = {
          string = device_symbol(dev.name),
          color = dev.connected and colors.white
            or colors.with_alpha(colors.white, 0.72),
        },
      })
    else
      paired_glyphs[i]:set({ drawing = false })
    end
    if not dev then
      paired_rows[i]:set({ drawing = false })
    elseif dev.connected then
      paired_rows[i]:set({
        drawing = true,
        background = { color = row_active, drawing = true },
        icon = {
          string = dev.name,
          color = colors.white,
          width = name_width_with_button,
        },
        label = action_label(
          "Disconnect", pressed_row == i and disconnect_red or disconnect_bg),
      })
    else
      local show_connect = hovered_address == dev.address:lower()
      paired_rows[i]:set({
        drawing = true,
        background = { color = colors.transparent, drawing = false },
        icon = {
          string = dev.name,
          color = colors.with_alpha(colors.white, 0.72),
          width = show_connect and name_width_with_button or name_width,
        },
        label = show_connect and action_label("Connect", disconnect_bg)
          or { drawing = false, background = { drawing = false } },
      })
    end
  end
end

local function refresh_paired(callback)
  sbar.exec(blueutil("--power") .. " 2>&1", function(power)
    local state = power:match("^%s*([01])%s*$")
    bt_power = state ~= "0"
    if state == nil or not bt_power then
      paired_cache = {}
      pressed_row = nil
      hovered_address = nil
      paint_paired()
      if callback then callback() end
      return
    end
    sbar.exec("'" .. bt_script:gsub("'", "'\\''") .. "' 2>/dev/null", function(output)
      pressed_row = nil
      paired_cache = {}
      for line in string.gmatch(output or "", "[^\n]+") do
        local name, address, connected_str =
          line:match("^([^|]*)|([^|]*)|([01])|")
        if name and address and #paired_cache < max_devices then
          paired_cache[#paired_cache + 1] = {
            name = name,
            address = address,
            connected = connected_str == "1",
          }
        end
      end
      paint_paired()
      if callback then callback() end
    end)
  end)
end

local function run_inquiry()
  if busy or not bt_power then return end
  busy = true
  spinner.start()
  sbar.exec(blueutil("--inquiry 8") .. " 2>/dev/null", function(output)
    busy = false
    spinner.stop()
    local paired_addrs = {}
    for _, dev in ipairs(paired_cache) do paired_addrs[dev.address:lower()] = true end
    nearby_cache = {}
    local seen = {}
    for line in string.gmatch(output or "", "[^\n]+") do
      local address = line:match("address: ([%x%-:]+)")
      if address and not seen[address:lower()] and not paired_addrs[address:lower()]
          and #nearby_cache < max_devices then
        seen[address:lower()] = true
        local name = line:match('name: "([^"]*)"')
        nearby_cache[#nearby_cache + 1] = {
          name = (name and name ~= "") and name or address,
          address = address,
        }
      end
    end
    for i = 1, max_devices do
      local dev = nearby_cache[i]
      if dev then
        nearby_glyphs[i]:set({
          drawing = true,
          icon = { string = device_symbol(dev.name) },
        })
        nearby_rows[i]:set({ drawing = true, icon = { string = dev.name } })
      else
        nearby_glyphs[i]:set({ drawing = false })
        nearby_rows[i]:set({ drawing = false })
      end
    end
  end)
end

local function collapse()
  hovered_address = nil
  bt_bracket:set({ popup = { drawing = false } })
end

local function toggle_connection(i)
  local dev = paired_cache[i]
  if not dev or busy then return end
  busy = true
  if dev.connected then
    pressed_row = i
    paint_paired()
  end
  local action = dev.connected and "--disconnect" or "--connect"
  sbar.exec(blueutil(action .. " " .. shell.quote(dev.address)) .. " 2>/dev/null", function()
    busy = false
    sbar.delay(0.8, function() refresh_paired() end)
  end)
end

for i = 1, max_devices do
  paired_rows[i]:subscribe("mouse.entered", function()
    local dev = paired_cache[i]
    if not dev or dev.connected then return end
    hovered_address = dev.address:lower()
    paint_paired()
  end)
  paired_rows[i]:subscribe("mouse.exited", function()
    local dev = paired_cache[i]
    if not dev or hovered_address ~= dev.address:lower() then return end
    hovered_address = nil
    paint_paired()
  end)
  paired_rows[i]:subscribe("mouse.clicked", function() toggle_connection(i) end)
  nearby_rows[i]:subscribe("mouse.clicked", function()
    local dev = nearby_cache[i]
    if not dev or busy then return end
    busy = true
    nearby_rows[i]:set({ label = { string = "…" } })
    sbar.exec(
      blueutil("--pair " .. shell.quote(dev.address)) .. " >/dev/null 2>&1 && "
        .. blueutil("--connect " .. shell.quote(dev.address)) .. " >/dev/null 2>&1"
        .. " && echo ok || echo fail",
      function()
        busy = false
        refresh_paired(run_inquiry)
      end)
  end)
end

local function toggle_popup()
  local open = bt_bracket:query().popup.drawing == "off"
  if open then
    bt_bracket:set({ popup = { drawing = true } })
    refresh_paired(run_inquiry)
  else
    collapse()
  end
end

bt_icon:subscribe("mouse.clicked", toggle_popup)
bt_icon:subscribe("mouse.exited.global", collapse)

sbar.add("item", "widgets.bluetooth.padding", {
  position = "right",
  width = settings.group_paddings,
})
