# sketchybar-glass on Windows — what changed and why

This directory is the Windows port of YBar's flagship macOS theme (the
"Liquid Glass" restyle of a full sketchybar setup). The Lua runtime is
byte-identical to macOS YBar's, so the `sketchybar.lua` compat shim, the
glass overlay files, and the item structure port verbatim; only OS-facing
surfaces differ. Same-named files should diff against the macOS tree
(`examples/sketchybar-glass` + `examples/sketchybar-port` on `main`) with
only OS-inherent changes.

## Layout difference

The macOS theme overlays `../sketchybar-port` (two trees, `package.path`
tricks). Here everything is vendored in this one directory — a theme
installed via `ybar theme use` must be self-contained.

## Replaced mechanisms

| macOS | Windows |
|---|---|
| SF Pro / SF Mono | Segoe UI / Cascadia Mono (Heavy/Black → Bold) |
| SF-Symbols glyph literals (icons.lua) | `sf:<name>` strings resolved against Segoe Fluent Icons |
| sketchybar-app-font app glyphs | dropped; front_app is label-only by owner preference (the engine can show the real shell icon via `image = "app.<Name>"` if wanted) |
| AeroSpace CLI workspace discovery | komorebi event env (`WORKSPACES`, `FOCUSED_WORKSPACE_INDEX`) — no CLI probing, no boot race |
| `aerospace workspace <ws>` clicks | `ybar --komorebi '{"type":"FocusNamedWorkspace",...}'` |
| pmset / battery CLI | native `battery_change`/`power_source_change` events + one `Win32_Battery` WMI query for popup details |
| networksetup / wifi_scan.py | native `wifi_change` event + `netsh wlan show interfaces` for popup details |
| osascript volume | native `volume_change` event + volume media keys for scroll-to-adjust |
| media artwork + app matching | `media_change` env (no artwork); transport via media-key synthesis |
| `x-apple.systempreferences:` links | `explorer.exe "ms-settings:..."` deep links |
| `open -a Calendar` | `explorer.exe outlookcal:` |

## Dropped (no Windows concept)

- `items/menus.lua` — the app-menu title swap reads the frontmost app's
  NSMenu; Windows apps have no global menu bar.
- `widgets/menubar.lua` — status-item capture (tray icons are toolbar
  buttons inside Explorer with no per-icon capture API; spec §10.6).
- `widgets/altserver.lua`, `widgets/skhd_mode.lua`, `widgets/claude.lua` —
  macOS-specific tooling.
- Calendar popup event rows — EventKit; the popup keeps the date header and
  an Open Calendar row.
- Per-device Bluetooth battery — no public API without pairing-level access.

## Glass rendering

The bar's `glass = true` gets a real Acrylic backdrop (DWM). Item-level
glass renders as the shader's specular rim + translucent fill — per-pill
backdrop blur has no Windows analog (spec §7.6); the bar backdrop carries
the material instead.
