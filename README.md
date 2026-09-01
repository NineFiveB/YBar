# ybar-win

**Top bar for Windows** — a GPU-rendered (D3D11 + DirectComposition),
scriptable status bar with first-class [komorebi](https://github.com/LGUG2Z/komorebi)
integration. A native C++ implementation of [YBar](https://github.com/NineFiveB/YBar)
that preserves its user contract: the sketchybar-style CLI/IPC grammar, the
embedded Lua 5.4 config runtime, themes, and the script/event environment.
Configs and themes written for YBar on macOS run here with only OS-inherent
edits (see [Porting a macOS config](#porting-a-macos-config)).

The authoritative design and parity contract is
[docs/WINDOWS-PORT.md](docs/WINDOWS-PORT.md).

This lives on the **`windows` branch** of the YBar repository — an orphan
branch with its own root history that never merges with `main`. Check it out
next to the macOS tree with:

```powershell
git worktree add ..\ybar-win windows
```

## Install

Download `ybar-win.zip` from the latest CI run and unpack it anywhere. The
payload is self-contained — a statically linked `ybar.exe`, the shader it
compiles at runtime, the shipped themes, and an app-local `d3dcompiler_47.dll`:

```
ybar.exe
shaders\ybar.hlsl
examples\<theme>\ybarrc.jsonc
d3dcompiler_47.dll
```

Put the folder on your `PATH` so config scripts can call `ybar` back. Then:

```powershell
ybar autostart enable    # HKCU Run entry; shows up in Task Manager > Startup apps
ybar                     # start the daemon
```

Release binaries are Authenticode-signed (Azure Trusted Signing). SmartScreen
may still warn until the certificate accrues reputation.

## Quick start

`ybar` with no arguments starts the daemon and loads the first config it finds
in `%USERPROFILE%\.config\ybar\`: `ybarrc.lua`, then `ybar.jsonc`, then
`ybarrc.jsonc`. `-c <path>` overrides that.

Everything else is a client command sent to the running daemon:

```powershell
ybar --bar height=34 color=0xee1e1e2e position=top
ybar --add item clock right
ybar --set clock icon=sf:clock update_freq=1 script='ybar --set clock "label=$(date +%H:%M)"'
ybar --subscribe clock system_woke
ybar --animate tanh 30 --set clock label.color=0xffff0000
ybar --query bar
```

## Themes

```powershell
ybar theme list            # shipped themes + anything in ~/.config/ybar/themes
ybar theme use catppuccin-komorebi
ybar theme current
```

`use` records the choice in `%USERPROFILE%\.config\ybar\current-theme` and
re-points a running daemon immediately. A theme is any directory containing
`ybarrc.lua`, `ybar.jsonc`, or `ybarrc.jsonc`.

## komorebi

komorebi is detected automatically. When it is running, ybar subscribes to its
socket and publishes `komorebi_workspace_change` with `FOCUSED_WORKSPACE`,
`PREV_WORKSPACE`, and `FOCUSED_MONITOR_INDEX`; window `Show`/`Destroy` events
become `app_launched`/`app_terminated`; and ybar reserves its strip through
`MonitorWorkAreaOffset` so tiled windows do not sit underneath it.

Reservation is controlled by `--bar reserve=`:

| Value | Behaviour |
|---|---|
| `komorebi` | reserve through komorebi (default when komorebi is detected) |
| `appbar` | reserve through the shell (`SHAppBarMessage`) — use without a tiling WM |
| `off` | reserve nothing |
| `auto` | komorebi when detected, else off |

The two reservation modes are mutually exclusive by construction; enabling both
would reserve the strip twice.

`ybar --komorebi '<json>'` forwards a raw `SocketMessage` to komorebi, which is
how theme click handlers drive it:

```powershell
ybar --komorebi '{"type":"CycleFocusWorkspace","content":"Next"}'
```

ybar re-detects komorebi once per second, so starting komorebi after ybar
attaches on its own — no restart needed.

## Events

Twenty builtin events, plus any custom event you register with
`--add event <name>`:

`front_app_switched`, `space_change`, `display_change`, `system_woke`,
`system_will_sleep`, `mouse.entered`, `mouse.exited`, `mouse.clicked`,
`mouse.scrolled`, `volume_change`, `power_source_change`, `battery_change`,
`wifi_change`, `system_stats`, `mouse.exited.global`, `mouse.entered.global`,
`modifier_change`, `app_launched`, `app_terminated`, `media_change`.

Providers arm on first subscription, so a config that never mentions an event
pays nothing for it. Scripts receive `NAME`, `SENDER`, `INFO`, and any
event-specific variables (`FOCUSED_WORKSPACE`, `MEDIA_TITLE`, `CPU_USAGE`,
`MODIFIER`, …).

### Windows-specific behaviour

- **SSID.** Windows 11 24H2 gates the SSID behind the Location privacy
  setting. Without it, `wifi_change` reports `"connected"` instead of the
  network name — the same degradation macOS has without Core Location.
  `ybar --bar wifi_ssid_prompt=on` opens the privacy page.
- **Media.** `media_change` comes from the system media transport controls, so
  it covers Spotify, browsers, and anything else that registers a session —
  a superset of the macOS implementation. `MEDIA_APP` carries the session's
  app id, not a friendly name.
- **App lifecycle.** With komorebi these events are window-scoped. Without it,
  ybar falls back to a process snapshot diff, so background processes with no
  UI also appear.
- **Elevated windows.** A non-elevated process's low-level hooks do not see
  input delivered to elevated windows, so popup auto-close and
  `modifier_change` go quiet while an elevated app has focus.

## Porting a macOS config

The grammar, property paths, event names, and Lua API are identical. What
changes:

| macOS | Windows |
|---|---|
| `sf:` SF Symbols | resolved against Segoe Fluent Icons — most common names map; unmapped ones draw a placeholder and warn once |
| `x-apple.systempreferences:` links | `ms-settings:` URIs (`ms-settings:sound`, `ms-settings:network-wifi`, `ms-settings:batterysaver`) |
| `osascript` media/volume snippets | unnecessary — media and volume are native providers |
| `alias` items (menu-bar extras) | not supported; `--add alias` returns an error |
| per-item `glass` pills | rendered as the shader's glass rim and translucent fill only |

Scripts run under `sh` — `%YBAR_SHELL%` if set, else `sh.exe` on `PATH` (Git
Bash), else Git for Windows' `sh.exe` found via the registry, else
`powershell.exe -NoProfile`. Write `$INFO`, not `$env:INFO`.

## Building

Requires Visual Studio 2022 C++ tools, CMake ≥ 3.24, and
[vcpkg](https://github.com/microsoft/vcpkg) (`VCPKG_ROOT` set).

```powershell
cmake --preset default
cmake --build --preset default
ctest --preset default
```

## Layout

| Path | Contents | Spec |
|---|---|---|
| `src/ipc/` | wire format, socket server/client, command parser/handler | §3.1–3.2, §5.1, §9 |
| `src/app/` | daemon lifecycle, message loop, config discovery/exec, hotload, local verbs | §5, §12–13 |
| `src/model/` | items, styles, components, layout, property setter, query serialization | §3.3, §8 |
| `src/anim/` | curves, scheduler (frame-clock paced) | §3.8 |
| `src/render/` | D3D11 renderer, scene builder, glyph atlas, DirectWrite font cache, icon map | §7 |
| `src/win/` | bar/popup surfaces (HWND + DComp), displays, input, backdrops, appbar | §6 |
| `src/providers/` | audio, network, app lifecycle/info, media (GSMTC), **komorebi**, ytile | §10, §11 |
| `src/lua/` | vendored Lua 5.4 (C), bridge, prelude | §3.7, §12 |
| `shaders/ybar.hlsl` | the SDF/glyph pipeline, compiled at runtime with `D3DCompile` | §7.3 |
| `tests/` | Catch2 contract tests (ported from the Swift suite) | §14 |

## License

GPL-3.0-only, same as YBar. komorebi is a separate program under its own
license; ybar-win only communicates with it over its socket and neither links
nor redistributes any komorebi code.
