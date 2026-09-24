# ysuite-liquid

The ysuite-web “Liquid Glass on Metal” mock as a running theme.

Full-bleed strip kept clear so each 28pt capsule pill carries its own glass (the mock's traveling sheen stays off), Apple menu and the menus/workspace swap (4pt crossfade) on the left. On the right, left to right: CPU sparkline, Wi-Fi, Bluetooth, battery capsule, clock. Battery popup mirrors the mock (24h/10d history, last charged); CPU popup adds a Disk · ↓ · ↑ footer.

```sh
ybar theme use ysuite-liquid
```

Needs `examples/sketchybar-port` beside this directory. Optional:
`ybar --bar wifi_ssid_prompt=on` once for the Wi-Fi network names (Location
Services).

Prerequisites: [Symbols Nerd Font](https://www.nerdfonts.com) for the
Bluetooth pill's logo glyph (this theme's own `items/widgets/bluetooth.lua`
is its only user; the port's Wi-Fi and Bluetooth files, the port's only
users, are replaced by the ones in this directory), and `blueutil`
(`brew install blueutil`) for the Bluetooth popup. The app-menus swap needs
the port's `menus` helper, which only `make helpers` from a clone builds — a
`brew install` never has it, so the swap is a no-op there (see
[`../sketchybar-port/README.md`](../sketchybar-port/README.md)).
