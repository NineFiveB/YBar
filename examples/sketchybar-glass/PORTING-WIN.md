# sketchybar-glass on Windows — what changed and why

This directory is the Windows port of YBar's flagship macOS theme (the
"Liquid Glass" restyle of a full sketchybar setup). The Lua runtime is
byte-identical to macOS YBar's apart from two Windows-only additions,
`ybar.tray` and `ybar.volume` (src/lua/runtime.cpp), so the `sketchybar.lua`
compat shim (plus a one-line `sbar.tray` passthrough), the item files, and
the item structure port verbatim; only OS-facing surfaces differ. Same-named
item files should diff against the macOS tree (`examples/sketchybar-glass` +
`examples/sketchybar-port` on `main`) with only OS-inherent changes. The
overlay files (`bar.lua`, `default.lua`, `colors.lua`) diverge on purpose:
they restyle the theme Fluent-flat — `glass = false`, popup
`blur_radius = 0`, a 35pt bar, opaque pill tones — instead of reproducing
Liquid Glass; `helpers/default_font.lua` carries only the font substitution
from the table below.

## Layout difference

The macOS theme overlays `../sketchybar-port` (two trees, `package.path`
tricks). Here everything is vendored in this one directory — a theme
installed via `ybar theme use` must be self-contained.

## Replaced mechanisms

| macOS | Windows |
|---|---|
| SF Pro / SF Mono | Segoe UI / Cascadia Mono (Heavy/Black → Bold) |
| SF-Symbols glyph literals (icons.lua) | `sf:<name>` strings resolved against Segoe Fluent Icons |
| sketchybar-app-font app glyphs | dropped; `items/front_app.lua` ships label-only but is not loaded — `items/init.lua` comments out its require (the name earned no strip room once the menus click was inert). Uncomment to bring it back; the engine can then show the real shell icon via `image = "app.<Name>"` if wanted |
| AeroSpace CLI workspace discovery | komorebi event env (`WORKSPACES`, `FOCUSED_WORKSPACE_INDEX`) — no CLI probing, no boot race |
| `aerospace workspace <ws>` clicks | `ybar --komorebi '{"type":"FocusWorkspaceNumber","content":<slot-1>}'` (index-based, so unnamed workspaces focus too) |
| pmset / battery CLI | native `battery_change`/`power_source_change` events + one `Win32_Battery` WMI query for popup details |
| networksetup / wifi_scan.py | native `wifi_change` event + `netsh wlan show interfaces` for the connected block, `netsh wlan show networks mode=bssid` (after a WinRT `WiFiAdapter.ScanAsync` nudge, rescanned every 12 s while open) for the network list, and `netsh wlan connect` for saved-profile row clicks |
| osascript volume | native `volume_change` event; absolute sets via in-process `ybar.volume(pct)` (sliders); volume media keys survive only in the currently unused `helpers/win.lua` `volume_scroll` helper (relative nudges that want the OS volume OSD) — no item wires it up. The bluetooth flyout's chevron additionally opens a per-app mixer (`ybar.query_table("audio")` rows + `ybar.volume(pct, id)`) — a Windows-only addition: macOS has no per-app volume API, so the macOS theme has no counterpart to diverge from |
| media artwork + app matching | `media_change` env (no artwork); transport via media-key synthesis |
| `x-apple.systempreferences:` links | `explorer.exe "ms-settings:..."` deep links |
| `open -a Calendar` | `explorer.exe outlookcal:` |

## Icon-font rules

- `sf:` strings resolve as WHOLE strings — a glyph cannot be concatenated
  into a text string. Split the glyph and the text across the item's two
  parts (icon = the `sf:` glyph, label = the text) or drop the glyph — the
  image path resolves only `app.<Name>`, `exe.<path>` and file paths
  (src/render/glyph_atlas.cpp), so an `sf.` image source currently draws
  nothing.
- Literal Segoe Fluent PUA characters (icons.lua's `switch`/`signal`
  tables) render only in a part whose `font.family` is the icon font —
  and that part must then hold PUA glyphs ONLY. Segoe Fluent Icons is a
  symbol font, and DirectWrite never font-falls-back out of a symbol
  font, so any regular text in the same part shapes to `.notdef` boxes
  (bitten live by the wifi rows' ssids; spec 7.4).

## Dropped (no Windows concept)

- `items/menus.lua` — the app-menu title swap reads the frontmost app's
  NSMenu; Windows apps have no global menu bar.
- `widgets/menubar.lua` — status-item capture (the notification area exposes
  no per-icon capture API; spec §10.6). A Windows-only tray popup,
  `widgets/apps.lua`, ships in its place: rows list the running tray apps
  (`sbar.query("tray")` — Explorer's `NotifyIconSettings` registrations, with
  their icons); left-click opens/restores, right-click quits behind an in-row
  confirm (`sbar.tray(name, "invoke"|"close")`).
- `widgets/altserver.lua`, `widgets/skhd_mode.lua`, `widgets/claude.lua` —
  macOS-specific tooling.
- Calendar popup event rows — EventKit; the popup keeps the date header and
  an Open Calendar row.
- Per-device Bluetooth battery and Connected state — each needs a per-device
  DEVPKEY property read (an extra round trip per device); dropped to keep the
  flyout a single probe.

## Deliberate restyles (not gaps)

- The wifi, bluetooth, and system-monitor popups left the macOS Settings
  layouts on purpose: they are Win11 Fluent flyouts (quick-settings header
  with a toggle glyph, single-line rows, plain-text Settings footer;
  Task Manager-style graphs in the monitor popup). The battery and media
  popups keep the shared macOS-derived layout.
- The macOS items' hover/reveal animations are not carried over: the
  spaces-indicator hover fade belongs to the dropped menus swap, and the
  emptied-workspace pill collapse/reveal slide is moot under the fixed
  komorebi slot set — pills snap by owner preference under the flat
  Fluent restyle.
- `items/apple.lua` (the system-menu pill, recast as a Windows menu with a
  Start-menu right-click) ships but is not loaded: `items/init.lua` comments
  out its require because a launcher covers what it offered. Uncomment to
  bring it back.

## Glass rendering

The theme ships Fluent-flat: `bar.lua` sets `glass = false` and
`default.lua` turns item/popup `glass` and popup `blur_radius` off — the
Windows default look is flat, while the macOS tree keeps Liquid Glass. Flip
them on to get the glass look back: the bar's `glass = true` gets a real
Acrylic backdrop (DWM). Item-level glass renders as the shader's specular
rim + translucent fill — per-pill backdrop blur has no Windows analog (spec
§7.6); the bar backdrop carries the material instead.
