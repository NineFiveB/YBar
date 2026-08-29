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
--   switch     -> literal Segoe Fluent ToggleRight/ToggleLeft chars
--                 (U+F19F/U+F19E exist in the font but not in the engine
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
      -- ToggleRight/ToggleLeft are complete switches with the knob baked in;
      -- ToggleFilled/ToggleBorder (U+EC11/U+EC12) are only the bare track —
      -- Windows layers a ToggleThumb glyph on top of those, which a single
      -- text part cannot do, so on screen they read as a featureless pill.
      on = "\239\134\159",   -- U+F19F ToggleRight (knob right = on)
      off = "\239\134\158",  -- U+F19E ToggleLeft (knob left = off)
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
      -- BatteryChargingN, N tenths filled: literal Segoe Fluent chars,
      -- the horizontal charging battery with the bolt. Charging0-8 run
      -- U+E85A..E862 sequentially; Charging9 is U+E83E (out of sequence —
      -- E863/E864 already start the BatterySaver LEAF run, rendered from a
      -- labeled 64px strip to pin this down). There is no Charging10:
      -- [10] is Battery10 (U+E83F), the solid full battery — "charged".
      -- Indexed [0..10] by floor(charge / 10); consumers must set
      -- font.family = ....font (only sf: strings auto-select the icon font).
      charging = {
        [0] = "\238\161\154", [1] = "\238\161\155", [2] = "\238\161\156",
        [3] = "\238\161\157", [4] = "\238\161\158", [5] = "\238\161\159",
        [6] = "\238\161\160", [7] = "\238\161\161", [8] = "\238\161\162",
        [9] = "\238\160\190", [10] = "\238\160\191",
        font = "Segoe Fluent Icons",
      }
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
        lock = "\238\156\174", -- U+E72E Lock (composited after an arc)
        unlock = "\238\158\133", -- U+E785 Unlock (open networks)
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
      -- ToggleRight/ToggleLeft are complete switches with the knob baked in;
      -- ToggleFilled/ToggleBorder (U+EC11/U+EC12) are only the bare track —
      -- Windows layers a ToggleThumb glyph on top of those, which a single
      -- text part cannot do, so on screen they read as a featureless pill.
      on = "\239\134\159",   -- U+F19F ToggleRight (knob right = on)
      off = "\239\134\158",  -- U+F19E ToggleLeft (knob left = off)
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
      -- BatteryChargingN, N tenths filled: literal Segoe Fluent chars,
      -- the horizontal charging battery with the bolt. Charging0-8 run
      -- U+E85A..E862 sequentially; Charging9 is U+E83E (out of sequence —
      -- E863/E864 already start the BatterySaver LEAF run, rendered from a
      -- labeled 64px strip to pin this down). There is no Charging10:
      -- [10] is Battery10 (U+E83F), the solid full battery — "charged".
      -- Indexed [0..10] by floor(charge / 10); consumers must set
      -- font.family = ....font (only sf: strings auto-select the icon font).
      charging = {
        [0] = "\238\161\154", [1] = "\238\161\155", [2] = "\238\161\156",
        [3] = "\238\161\157", [4] = "\238\161\158", [5] = "\238\161\159",
        [6] = "\238\161\160", [7] = "\238\161\161", [8] = "\238\161\162",
        [9] = "\238\160\190", [10] = "\238\160\191",
        font = "Segoe Fluent Icons",
      }
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
        lock = "\238\156\174", -- U+E72E Lock (composited after an arc)
        unlock = "\238\158\133", -- U+E785 Unlock (open networks)
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
