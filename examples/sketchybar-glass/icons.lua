local settings = require("settings")

-- Windows port: every icon is an "sf:<name>" reference resolved against
-- Segoe Fluent Icons by the engine (src/render/icon_map.cpp). Names with no
-- exact entry resolve through the progressive dotted-prefix fallback
-- ("speaker.wave.3.fill" -> "speaker.wave.3").
--
-- Substitutions where Segoe Fluent has no mapped equivalent in the engine:
--   loading    -> sf:arrow.clockwise  (no hourglass/spinner glyph mapped)
--   apple      -> sf:apps             (no Apple logo on Windows; Start-like
--                                      app grid stands in)
--   gpu        -> sf:display          (no discrete GPU glyph mapped)
--   disk       -> sf:folder           (no hard-drive glyph mapped)
--   clipboard  -> sf:doc              (no clipboard glyph mapped)
--   switch     -> literal Segoe Fluent ToggleFilled/ToggleBorder chars
--                 (U+EC11/U+EC12 exist in the font but not in the engine
--                 map; consumers must set font.family = icons.switch.font,
--                 since only sf: strings auto-select the icon font)
--   volume._10 -> sf:volume           (no bare wave-less speaker mapped)
--   charging   -> sf:bolt             (no combined battery+bolt glyph)
--   play_pause -> sf:play.fill        (no combined play/pause glyph)
local icons = {
  sf_symbols = {
    plus = "sf:plus",
    loading = "sf:arrow.clockwise",
    apple = "sf:apps",
    gear = "sf:gearshape",
    cpu = "sf:cpu",
    memory = "sf:memorychip",
    gpu = "sf:display",
    disk = "sf:folder",
    clipboard = "sf:doc",

    switch = {
      on = "\238\176\145",   -- U+EC11 ToggleFilled
      off = "\238\176\146",  -- U+EC12 ToggleBorder
      font = "Segoe Fluent Icons",
    },
    volume = {
      _100="sf:speaker.wave.3.fill",
      _66="sf:speaker.wave.2.fill",
      _33="sf:speaker.wave.1.fill",
      _10="sf:volume",
      _0="sf:speaker.slash.fill",
    },
    battery = {
      _100 = "sf:battery.100percent",
      _75 = "sf:battery.75percent",
      _50 = "sf:battery.50percent",
      _25 = "sf:battery.25percent",
      _0 = "sf:battery.0percent",
      charging = "sf:bolt"
    },
    bluetooth = "sf:bluetooth",
    wifi = {
      upload = "sf:arrow.up",
      download = "sf:arrow.down",
      connected = "sf:wifi",
      disconnected = "sf:wifi.slash",
      router = "sf:network",
      -- Literal Segoe Fluent chars (not in the engine map); consumers must
      -- set font.family = ....font, same as switch.
      signal = {
        _1 = "\238\161\178",  -- U+E872 Wifi1 (weakest, one arc)
        _2 = "\238\161\179",  -- U+E873 Wifi2
        _3 = "\238\161\180",  -- U+E874 Wifi3
        _4 = "\238\156\129",  -- U+E701 Wifi (full)
        font = "Segoe Fluent Icons",
      },
    },
    media = {
      back = "sf:backward.fill",
      forward = "sf:forward.fill",
      play_pause = "sf:play.fill",
    },
  },

  -- Alternative NerdFont icons. NerdFont glyphs are not renderable on
  -- Windows (icon strings must be sf: references), so this table mirrors
  -- the sf_symbols set — kept only so settings.icons = "NerdFont" still
  -- returns a working table.
  nerdfont = {
    plus = "sf:plus",
    loading = "sf:arrow.clockwise",
    apple = "sf:apps",
    gear = "sf:gearshape",
    cpu = "sf:cpu",
    memory = "sf:memorychip",
    gpu = "sf:display",
    disk = "sf:folder",
    clipboard = "sf:doc",

    switch = {
      on = "\238\176\145",   -- U+EC11 ToggleFilled
      off = "\238\176\146",  -- U+EC12 ToggleBorder
      font = "Segoe Fluent Icons",
    },
    volume = {
      _100="sf:speaker.wave.3.fill",
      _66="sf:speaker.wave.2.fill",
      _33="sf:speaker.wave.1.fill",
      _10="sf:volume",
      _0="sf:speaker.slash.fill",
    },
    battery = {
      _100 = "sf:battery.100percent",
      _75 = "sf:battery.75percent",
      _50 = "sf:battery.50percent",
      _25 = "sf:battery.25percent",
      _0 = "sf:battery.0percent",
      charging = "sf:bolt"
    },
    bluetooth = "sf:bluetooth",
    wifi = {
      upload = "sf:arrow.up",
      download = "sf:arrow.down",
      connected = "sf:wifi",
      disconnected = "sf:wifi.slash",
      router = "sf:network",
      -- Literal Segoe Fluent chars (not in the engine map); consumers must
      -- set font.family = ....font, same as switch.
      signal = {
        _1 = "\238\161\178",  -- U+E872 Wifi1 (weakest, one arc)
        _2 = "\238\161\179",  -- U+E873 Wifi2
        _3 = "\238\161\180",  -- U+E874 Wifi3
        _4 = "\238\156\129",  -- U+E701 Wifi (full)
        font = "Segoe Fluent Icons",
      },
    },
    media = {
      back = "sf:backward.fill",
      forward = "sf:forward.fill",
      play_pause = "sf:play.fill",
    },
  },
}

if not (settings.icons == "NerdFont") then
  return icons.sf_symbols
else
  return icons.nerdfont
end
