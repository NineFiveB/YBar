local colors = require("colors")

-- Right powerline chain. Visual order left-to-right:
--   > wifi (gray) > volume (orange) > battery (aqua) > clock (yellow)
-- Right-position items are added rightmost-first, so the code below runs
-- clock, battery, volume, wifi. Between blocks sits a separator item whose
-- icon is the solid left-pointing powerline arrow, colored as the NEXT
-- (righthand) segment and drawn on the PREVIOUS (lefthand) segment's
-- background — bar background at the chain start — so the blocks flow
-- into each other with no gaps.

local ARROW = "\u{E0B2}"   -- powerline left-pointing solid triangle

-- Separator: fg = the segment color growing in from the right, bg = the
-- segment it grows out of (nil at the chain start, the bar shows through).
local function separator(name, fg, bg)
  sbar.add("item", name, {
    position = "right",
    icon = {
      string = ARROW,
      color = fg,
      font = { family = "Symbols Nerd Font", style = "Regular", size = 22.0 },
      padding_left = 0,
      padding_right = 0,
    },
    label = { drawing = false },
    background = bg and { color = bg, corner_radius = 0, height = 30 } or nil,
    padding_left = 0,
    padding_right = 0,
  })
end

-- ── Clock: yellow, rightmost ──────────────────────────────────────────────
local clock = sbar.add("item", "gruvbox.clock", {
  position = "right",
  update_freq = 20,
  icon = { string = "\u{F0954}", color = colors.dark },
  label = { color = colors.dark },
  background = { color = colors.yellow, corner_radius = 0, height = 30 },
})
clock:subscribe({ "forced", "routine", "system_woke" }, function()
  clock:set({ label = os.date("%a %d %b %H:%M") })
end)

separator("gruvbox.sep.clock", colors.yellow, colors.aqua)

-- ── Battery: aqua, pmset fallback for the level ───────────────────────────
local battery = sbar.add("item", "gruvbox.battery", {
  position = "right",
  icon = { string = "\u{F0079}", color = colors.dark },
  label = { color = colors.dark },
  background = { color = colors.aqua, corner_radius = 0, height = 30 },
})

local function battery_render(level, charging)
  local glyph
  if charging then
    glyph = "\u{F0084}"                      -- battery-charging
  elseif level >= 95 then
    glyph = "\u{F0079}"                      -- battery (full)
  else
    -- battery-10 .. battery-90 are consecutive codepoints from U+F007A.
    glyph = utf8.char(0xF0079 + math.max(1, math.floor(level / 10)))
  end
  battery:set({ icon = { string = glyph }, label = { string = level .. "%" } })
end

battery:subscribe({ "forced", "battery_change", "power_source_change" }, function(env)
  local pct = tonumber(env.INFO) or tonumber((env.INFO or ""):match("%d+"))
  if pct then
    battery_render(pct, false)
    return
  end
  sbar.exec("pmset -g batt", function(out)
    local level = tonumber(out:match("(%d+)%%")) or 0
    battery_render(level, out:find("AC Power") ~= nil)
  end)
end)

separator("gruvbox.sep.battery", colors.aqua, colors.orange)

-- ── Volume: orange ────────────────────────────────────────────────────────
local volume = sbar.add("item", "gruvbox.volume", {
  position = "right",
  icon = { string = "\u{F057E}", color = colors.dark },
  label = { color = colors.dark },
  background = { color = colors.orange, corner_radius = 0, height = 30 },
})
volume:subscribe("volume_change", function(env)
  local level = tonumber(env.INFO) or 0
  local glyph = level == 0 and "\u{F0581}"
    or (level < 40 and "\u{F057F}" or (level < 75 and "\u{F0580}" or "\u{F057E}"))
  volume:set({ icon = { string = glyph }, label = { string = level .. "%" } })
end)

sbar.trigger("volume_change")

separator("gruvbox.sep.volume", colors.orange, colors.gray)

-- ── Wifi: gray, chain start ───────────────────────────────────────────────
local wifi = sbar.add("item", "gruvbox.wifi", {
  position = "right",
  icon = { string = "\u{F0928}", color = colors.dark, padding_right = 8 },
  label = { drawing = false, color = colors.dark },
  background = { color = colors.gray, corner_radius = 0, height = 30 },
  click_script = "open 'x-apple.systempreferences:com.apple.wifi-settings-extension'",
})
wifi:subscribe("wifi_change", function(env)
  local info = env.INFO or ""
  local up = info ~= ""
  wifi:set({
    icon = { string = up and "\u{F0928}" or "\u{F092D}" },
    label = { drawing = up and info ~= "connected", string = info },
  })
end)

sbar.trigger("wifi_change")

separator("gruvbox.sep.wifi", colors.gray, nil)
