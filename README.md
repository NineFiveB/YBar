# ybar-win

**Top bar for Windows** — a GPU-rendered (D3D11 + Windows.UI.Composition),
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

One line, no admin rights (PowerShell):

```powershell
irm https://raw.githubusercontent.com/NineFiveB/YBar/windows/scripts/install.ps1 | iex
```

It downloads the latest signed `win-v*` release into
`%LOCALAPPDATA%\Programs\ybar`, verifies the SHA256 the release publishes
plus the Authenticode signature, and puts the directory on your `PATH`.
Options via env vars: `$env:YBAR_START=1` (launch when done),
`$env:YBAR_AUTOSTART=1` (run at login), `$env:YBAR_VERSION=0.1.0` (pin),
`$env:YBAR_UNINSTALL=1` (remove; same one-liner).
When it starts the daemon for you (`YBAR_START`, or an upgrade of a running
bar) its stderr goes to `%LOCALAPPDATA%\ybar\stderr.log` — the daemon's state
directory, which also holds the IPC socket that doubles as the single-instance
lock. Uninstall removes the install and state directories but leaves
`~\.config\ybar` alone.

Or with [Scoop](https://scoop.sh):

```powershell
scoop install https://raw.githubusercontent.com/NineFiveB/YBar/windows/packaging/scoop/ybar-win.json
```

The shim lands on your `PATH` as `ybar`, and `scoop update ybar-win` follows
new releases. A winget manifest is staged under `packaging/` for submission.

Or manually: download `ybar-win-<version>-x64.zip` from the latest
[`win-v*` release](../../releases) and unpack it anywhere. The payload is
self-contained — a statically linked `ybar.exe`, the shader it compiles at
runtime, the shipped themes, and an app-local `d3dcompiler_47.dll`:

```
ybar.exe
shaders\ybar.hlsl
examples\<theme>\ybarrc.lua or ybarrc.jsonc
d3dcompiler_47.dll
README.md
LICENSE
```

For a manual install, put the folder on your `PATH` so config scripts can
call `ybar` back (Scoop's shim already covers this). Then:

```powershell
ybar autostart enable    # HKCU Run entry; shows up in Task Manager > Startup apps
                         # (`autostart disable` removes it, `autostart status` reports it)
ybar                     # start the daemon
```

Release binaries are Authenticode-signed (Azure Trusted Signing). SmartScreen
may still warn until the certificate accrues reputation.

## Quick start

`ybar` with no arguments starts the daemon and loads the first config it finds
in `%XDG_CONFIG_HOME%\ybar\` (when set), then `%USERPROFILE%\.config\ybar\`:
`ybarrc.lua`, then `ybarrc`, then `ybarrc.jsonc`, then `ybar.jsonc`, falling
back to `~\.ybarrc.lua` / `~\.ybarrc`. A theme recorded with `ybar theme use`
takes precedence over that search; `-c <path>` overrides everything.

Everything else is a client command sent to the running daemon:

```powershell
ybar --bar height=34 color=0xee1e1e2e position=top
ybar --add item clock right
ybar --set clock icon=sf:clock update_freq=1 script='ybar --set clock "label=$(date +%H:%M)"'
ybar --subscribe clock system_woke
ybar --animate tanh 30 --set clock label.color=0xffff0000
ybar --query bar
```

The daemon verbs are sketchybar's: `--bar`, `--default`,
`--add item|graph|slider|bracket|event`, `--set`, `--subscribe`, `--trigger`,
`--animate`, `--update`, `--query bar|defaults|events|displays|<item>`,
`--push`, `--remove`, `--move`, `--reorder`, `--rename`, `--clone`,
`--reload [path]`, `--hotload on|off`, `--ping`, and `--exit`. Windows adds
`--komorebi`, `--volume`, `--tray`, `--window`, and
`--query windows|tray|audio` (see below). `ybar --help` (`-h`) and
`ybar --version` (`-v`) print locally, as do the `theme` and `autostart`
subcommands; `--config` is the long form of `-c`.

## Themes

```powershell
ybar theme list            # shipped themes + anything in ~/.config/ybar/themes
ybar theme use catppuccin-komorebi
ybar theme current
ybar theme reset           # forget the choice; normal config discovery applies again
```

`use` records the choice in `%USERPROFILE%\.config\ybar\current-theme` and
re-points a running daemon immediately. A theme is any directory containing
`ybarrc.lua`, `ybar.jsonc`, or `ybarrc.jsonc`.

## komorebi

komorebi is detected automatically. When it is running and `--bar reserve=`
is `auto` or `komorebi` (never under `appbar` or `off`), ybar subscribes to its
socket and publishes `komorebi_workspace_change` with `FOCUSED_WORKSPACE`,
`PREV_WORKSPACE`, `FOCUSED_MONITOR_INDEX`, `WORKSPACES` (the focused monitor's
workspace names, newline-separated) and `FOCUSED_WORKSPACE_INDEX` (1-based), and
fires `space_change` with the same variables; window `Show`/`Destroy` events
become `app_launched`/`app_terminated`; and ybar reserves its strip through
`MonitorWorkAreaOffset` so tiled windows do not sit underneath it.

Reservation is controlled by `--bar reserve=`:

| Value | Behaviour |
|---|---|
| `komorebi` | reserve through the tiling WM — behaves exactly like `auto` |
| `appbar` | reserve through the shell (`SHAppBarMessage`) — use without a tiling WM |
| `off` | reserve nothing |
| `auto` | komorebi when detected, else YTile when detected, else off — the default |

The two reservation modes are mutually exclusive by construction; enabling both
would reserve the strip twice.

`ybar --komorebi '<json>'` forwards a raw `SocketMessage` to komorebi, which is
how theme click handlers drive it:

```powershell
ybar --komorebi '{"type":"CycleFocusWorkspace","content":"Next"}'
```

ybar re-detects komorebi once per second, so starting komorebi after ybar
attaches on its own — no restart needed.

### YTile

YTile, the sibling tiling WM, is supported the same way: when komorebi is
absent and YTile is running (its `\\.\pipe\ytile` pipe exists), ybar
subscribes to it, reserves its strip through YTile, and publishes
`ytile_workspace_change` **and** `komorebi_workspace_change` with the same
variables (`WORKSPACES` lists the workspace numbers that are non-empty or
active), so komorebi themes work unchanged; window manage/unmanage feed
`app_launched`/`app_terminated`. `ybar --komorebi` keeps working too —
`FocusWorkspaceNumber`, `FocusNamedWorkspace` and `CycleFocusWorkspace` are
translated onto YTile. komorebi outranks: if it starts later, ybar hands over
to it.

## Events

Twenty builtin events, plus any custom event you register with
`--add event <name>`:

`front_app_switched`, `space_change`, `display_change`, `system_woke`,
`system_will_sleep`, `mouse.entered`, `mouse.exited`, `mouse.clicked`,
`mouse.scrolled`, `volume_change`, `power_source_change`, `battery_change`,
`wifi_change`, `system_stats`, `mouse.exited.global`, `mouse.entered.global`,
`modifier_change`, `app_launched`, `app_terminated`, `media_change`.

When a tiling WM is detected (and `reserve` is not `off`/`appbar`) the
daemon also registers two custom events of its own: `komorebi_workspace_change`
(fired for komorebi and for YTile alike, so themes work unchanged) and
`ytile_workspace_change` (YTile only); `space_change` fires alongside them
with the same variables.

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
- **Volume, tray, and windows.** `ybar --volume <0-100> [app]` sets the
  master volume, or one app's session group when given an `id` from
  `ybar --query audio`. `ybar --query tray` lists notification-area icons
  and `ybar --tray <name> invoke|close` activates or closes one;
  `ybar --query windows` lists running app windows and
  `ybar --window <hwnd> close|kill` posts `WM_CLOSE` to one or terminates
  its process. All are ybar-win extensions; the macOS build rejects them.
- **Diagnostics.** Start the daemon with `YBAR_DEBUG=1` set and it traces its
  bring-up, surface/DPI geometry and per-frame render statistics to stderr —
  worth attaching to a bug report.

## Porting a macOS config

The grammar, property paths, event names, and Lua API are identical. What
changes:

| macOS | Windows |
|---|---|
| `sf:` SF Symbols | resolved against Segoe Fluent Icons — most common names map; unmapped ones draw a placeholder and warn once |
| `x-apple.systempreferences:` links | `ms-settings:` URIs (`ms-settings:sound`, `ms-settings:network-wifi`, `ms-settings:batterysaver`) |
| `osascript` media/volume snippets | unnecessary — media and volume are native providers |
| `alias` items (menu-bar extras) | not supported; `--add alias` returns an error |
| per-item `glass` pills | a Mica wallpaper backdrop under the pill (Windows 11 compositor), tinted by the pill's own translucent fill, plus the shader's lit rim; popup items get the rim and fill only; Liquid Glass refraction is not reproduced |

Scripts run under `sh` — `%YBAR_SHELL%` if set, else `sh.exe` on `PATH` (Git
Bash), else Git for Windows' `sh.exe` found via the registry, else
`powershell.exe -NoProfile`. Write `$INFO`, not `$env:INFO`.

## Building

Requires Visual Studio 2022 C++ tools, CMake ≥ 3.25 (the presets file is
schema version 6), and
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
| `src/win/` | bar surface (HWND + Windows.UI.Composition, per-pill Mica layer), popup surface (HWND + DComp), displays, input, backdrops, appbar | §6, §7.6 |
| `src/providers/` | audio + per-app audio sessions, network, app lifecycle/info, media (GSMTC), window list, tray icons, **komorebi**, ytile | §10, §11 |
| `src/lua/` | vendored Lua 5.4 (C), bridge, prelude | §3.7, §12 |
| `shaders/ybar.hlsl` | the SDF/glyph pipeline, compiled at runtime with `D3DCompile` | §7.3 |
| `tests/` | Catch2 contract tests (ported from the Swift suite) | §14 |

## License

GPL-3.0-only, same as YBar. komorebi is a separate program under its own
license; ybar-win only communicates with it over its socket and neither links
nor redistributes any komorebi code.
