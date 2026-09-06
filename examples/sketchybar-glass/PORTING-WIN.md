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
they restyle the theme for Windows — a flat 35pt bar with no Acrylic, and
Mica pills and popup panels (a wallpaper-material backdrop under a
translucent tint, `colors.mica` for pills and `colors.popup.bg` for panels,
lit by the shader's rim) in place of Liquid Glass; `helpers/default_font.lua`
carries only the font substitution from the table below.

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

The bar itself stays flat: `bar.lua` sets `glass = false` (bar-level glass
is a DWM Acrylic plate that follows the Transparency-effects setting) and
`default.lua` leaves item `glass` off, so popup rows and separators never
pick the material up. `ybarrc.lua` then turns glass on BY NAME: item-level
for the six widget brackets and the calendar item, whose fill is
`colors.mica`, a 60% `#202020` tint, and popup-level for the seven popup
hosts, whose panel plate is `colors.popup.bg`, an 80% tint. On Windows
glass is Mica: a blurred-wallpaper visual composed under the pill or panel
(spec §7.6), with the translucent fill as the tint and the shader's lit rim
on top. It follows the pill (the focused workspace carries one too, via
`items/spaces.lua`), needs Windows 11, and works with Transparency effects
off. What it shows is the wallpaper: a wallpaper that is flat under the bar
gives flat grey pills, colour at the top of the wallpaper shows through
them, and a panel shows whatever the wallpaper has where it opens. A popup
row can cut its own material window in the panel plate (a Windows
extension), but only on the same gate as everything else: `blur_radius > 0`,
or `glass = true` with a fill that actually paints. The shipped rows rest
transparent, so `glass` alone would light them only while hovered; they stay
flat instead. Liquid Glass refraction is not reproduced.
