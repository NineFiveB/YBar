# YBar for Windows

A GPU-rendered, scriptable status bar for Windows 11, with first-class
[komorebi](https://github.com/LGUG2Z/komorebi) and YTile support. It is a
native C++ build of [YBar](https://github.com/NineFiveB/YBar). It keeps the
same user contract: the sketchybar-style CLI and socket grammar, the embedded
Lua 5.4 config runtime, themes, and the script and event environment. Configs
and themes written for YBar on macOS run here with only OS-specific edits (see
[Porting a macOS config](#porting-a-macos-config)).

Pictures and captions live on `main`:
https://github.com/NineFiveB/YBar/blob/main/docs/WINDOWS.md
The design and parity contract is
https://github.com/NineFiveB/YBar/blob/windows/docs/WINDOWS-PORT.md
The shared docs are on `main` too:
[CONFIG.md](https://github.com/NineFiveB/YBar/blob/main/docs/CONFIG.md),
[THEMES.md](https://github.com/NineFiveB/YBar/blob/main/docs/THEMES.md) and
[EXTENDING.md](https://github.com/NineFiveB/YBar/blob/main/docs/EXTENDING.md).

## Requirements

Windows 11 (21H2 or later; tested on 22H2 and later), x64. Mica pills and
popup panels need the Windows 11 compositor, and bar-level Acrylic needs
22H2; without them the bar draws flat fills. Windows 10 is untested.

## Install

One line, no admin rights (PowerShell):

```powershell
irm https://raw.githubusercontent.com/NineFiveB/YBar/windows/scripts/install.ps1 | iex
```

It downloads the latest `win-v*` release into `%LOCALAPPDATA%\Programs\ybar`
and puts that folder on your user `PATH`. It checks the zip against the SHA256
the release publishes: no hash, or a mismatch, and it refuses to install. It
also checks the Authenticode signature on `ybar.exe`: an unsigned build only
warns (forks build unsigned); a broken signature aborts. Options are env vars,
since a piped script takes no parameters: `$env:YBAR_START=1` (launch when
done), `$env:YBAR_AUTOSTART=1` (run at login), `$env:YBAR_VERSION=0.1.0`
(pin), `$env:YBAR_UNINSTALL=1` (remove; same one-liner). Upgrading a running
bar stops it and starts it again. When the installer starts the bar for you,
its stderr goes to `%LOCALAPPDATA%\ybar\stderr.log`. That folder is the
daemon's state directory; it also holds the IPC socket, which doubles as the
single-instance lock.

Or with [Scoop](https://scoop.sh):

```powershell
scoop install https://raw.githubusercontent.com/NineFiveB/YBar/windows/packaging/scoop/ybar-win.json
```

The shim lands on your `PATH` as `ybar`. `scoop update ybar-win` upgrades once
the manifest at that URL is bumped to a new release. A winget manifest is
staged under `packaging/`; it is not published yet.

Or the release zip: download `ybar-win-<version>-x64.zip` from the latest
`win-v*` release at https://github.com/NineFiveB/YBar/releases and unpack it
anywhere. The payload is self-contained: a statically linked `ybar.exe`, the
shader it compiles at startup, the shipped themes, and an app-local
`d3dcompiler_47.dll`:

```
ybar.exe
ybarw.exe
shaders\ybar.hlsl
examples\<theme>\ybarrc.lua or ybarrc.jsonc
d3dcompiler_47.dll
README.md
LICENSE
```

Put the folder on your `PATH` so you can run `ybar` from a terminal. Scripts
the bar spawns get its directory prepended to their `PATH` either way, so a
config can call `ybar` back without it. Release binaries are
Authenticode-signed (Azure Trusted Signing). SmartScreen may still warn until
the certificate accrues reputation.

### Start, autostart, status, stop

```powershell
ybar start               # launch the bar in the background, no console window
ybar autostart enable    # start it at every login (HKCU Run entry; shows up in
                         # Task Manager > Startup apps; `autostart disable` removes
                         # it, `autostart status` reports it)
ybar status              # bar, config and autostart state, and the log path
ybar stop                # stop it; `ybar restart [-c <path>]` stops and relaunches
```

`ybar.exe` is a console program: a shell waits for it and sees its exit code,
and Explorer or the Run key would give it a console window. `ybarw.exe` beside
it runs `ybar start` with no window (`w` as in `pythonw`); double-click it, or
point a shortcut or the Run key at it. Double-clicking `ybar.exe` itself works
too: it hands the bar to a detached copy and closes its console. A bar started
this way writes its stderr to `%LOCALAPPDATA%\ybar\stderr.log`, which
`ybar status` names. Once that file exceeds 1 MB it is rolled over to
`stderr.log.1` at the next start. Bare `ybar` in a terminal still runs the
daemon in that terminal, for watching it.

### Uninstall

- **PowerShell install:** `$env:YBAR_UNINSTALL=1`, then the same one-liner. It
  stops the bar, removes the autostart entry and the `PATH` entry, and deletes
  `%LOCALAPPDATA%\Programs\ybar` and `%LOCALAPPDATA%\ybar`.
- **Scoop:** `ybar stop`, `ybar autostart disable`, then
  `scoop uninstall ybar-win`. Delete `%LOCALAPPDATA%\ybar` by hand.
- **Zip:** `ybar stop`, `ybar autostart disable`, delete the folder you
  unpacked and `%LOCALAPPDATA%\ybar`, and drop the `PATH` entry you added.

All three leave `~\.config\ybar` alone, so your config and theme choice
survive a reinstall.

## Quick start

`ybar start` (or bare `ybar`, in the foreground) loads the first config it
finds. It looks in `%XDG_CONFIG_HOME%\ybar\` when that variable is set, then
in `%USERPROFILE%\.config\ybar\`. In each directory it tries `ybarrc.lua`,
then `ybarrc`, then `ybarrc.jsonc`, then `ybar.jsonc`. Last it falls back to
`~\.ybarrc.lua`, then `~\.ybarrc`. A theme recorded with `ybar theme use`
takes precedence over that search; `-c <path>` overrides everything. The
fastest start is a shipped theme: `ybar theme use sketchybar-glass`.

Everything else is a client command sent to the running daemon:

```powershell
ybar --bar height=34 color=0xee1e1e2e position=top
ybar --add item clock right
ybar --set clock icon=sf:clock update_freq=1 script='ybar --set clock "label=$(date +%H:%M)"'
ybar --subscribe clock system_woke
ybar --animate tanh 30 --set clock label.color=0xffff0000
ybar --query bar
```

Scripts like that `$(date)` one run under `sh`: `%YBAR_SHELL%` if set, else
`sh.exe` on `PATH` (Git Bash), else Git for Windows' `sh.exe` found via the
registry, else `powershell.exe -NoProfile`. Write `$INFO`, not `$env:INFO`.

The daemon verbs are sketchybar's: `--bar`, `--default`,
`--add item|graph|slider|bracket|event`, `--set`, `--subscribe`, `--trigger`,
`--animate`, `--update`, `--query bar|defaults|events|displays|<item>`,
`--push`, `--remove`, `--move`, `--reorder`, `--rename`, `--clone`,
`--reload [path]`, `--hotload on|off`, `--ping`, and `--exit`.
`--volume <0-100>` exists on both platforms; macOS also takes `+N`/`-N` steps,
which Windows does not. Windows adds `--komorebi '<json>'`,
`--tray <name> invoke|close`, `--window <hwnd> close|kill`,
`--bluetooth scan on|off`, `--bluetooth pair <id>`, an optional second token
on `--volume` for one app, and `--query windows|tray|audio|bluetooth` (see
below). `ybar --help` (`-h`) and `ybar --version` (`-v`) print locally, as do
the `start`/`stop`/`restart`/`status`, `theme` and `autostart` subcommands;
`--config` is the long form of `-c`. Exit codes: 0 success (idempotent no-ops
included, such as `stop` when nothing runs), 1 the operation failed or the
daemon rejected a message, 2 the invocation was wrong.

## Themes

```powershell
ybar theme list            # shipped themes beside the exe (examples\, themes\) + ~/.config/ybar/themes
ybar theme use sketchybar-glass
ybar theme current
ybar theme reset           # forget the choice; normal config discovery applies again
```

`use` records the choice in `%USERPROFILE%\.config\ybar\current-theme` and
re-points a running daemon at once. A theme is any directory containing
`ybarrc.lua`, `ybar.jsonc`, or `ybarrc.jsonc`. Two themes ship on Windows:
`sketchybar-glass` (Lua, the macOS flagship ported; see
[examples/sketchybar-glass/PORTING-WIN.md](examples/sketchybar-glass/PORTING-WIN.md))
and `catppuccin-komorebi` (JSONC). The other macOS themes on `main` are not
ported.

## komorebi and YTile

komorebi is detected automatically. When it is running and `--bar reserve=`
is `auto` or `komorebi` (never under `appbar` or `off`), ybar subscribes to
its socket. It publishes `komorebi_workspace_change` with `FOCUSED_WORKSPACE`,
`PREV_WORKSPACE`, `FOCUSED_MONITOR_INDEX`, `WORKSPACES` (the focused monitor's
workspace names, newline-separated) and `FOCUSED_WORKSPACE_INDEX` (1-based).
`space_change` fires alongside with the same variables. Window `Show` and
`Destroy` notifications become `app_launched` and `app_terminated`. And ybar
reserves its strip through `MonitorWorkAreaOffset` on every monitor, so tiled
windows do not sit underneath it. Do not also set `global_work_area_offset`
(or a per-monitor `work_area_offset`) for the bar in `komorebi.json`. ybar
sends the offset itself and zeroes it again on exit, so a static one would
reserve the strip twice.

Reservation is controlled by `--bar reserve=`:

| Value | Behavior |
|---|---|
| `komorebi` | reserve through the tiling WM; behaves exactly like `auto` |
| `appbar` | reserve through the shell (`SHAppBarMessage`); use without a tiling WM |
| `off` | reserve nothing |
| `auto` | komorebi when detected, else YTile when detected, else off; the default |

The two reservation modes are mutually exclusive by construction; enabling
both would reserve the strip twice.

`ybar --komorebi '<json>'` forwards a raw `SocketMessage` to komorebi, which
is how theme click handlers drive it:

```powershell
ybar --komorebi '{"type":"CycleFocusWorkspace","content":"Next"}'
```

ybar re-detects komorebi once per second, so starting komorebi after ybar
attaches on its own; no restart needed.

### YTile

YTile, the sibling tiling WM, works the same way. When komorebi is absent and
YTile is running (its `\\.\pipe\ytile` pipe exists), ybar subscribes to it and
reserves its strip through YTile. It publishes `ytile_workspace_change` **and**
`komorebi_workspace_change` with the same variables, so komorebi themes work
unchanged; here `WORKSPACES` lists the workspace numbers that are non-empty or
active. Window manage and unmanage feed `app_launched` and `app_terminated`.
`ybar --komorebi` keeps working too: `FocusWorkspaceNumber`,
`FocusNamedWorkspace` and `CycleFocusWorkspace` are translated onto YTile.
komorebi outranks: if it starts later, ybar hands over to it.

## Events

Twenty-two builtin events, plus any custom event you register with
`--add event <name>`:

`front_app_switched`, `space_change`, `display_change`, `system_woke`,
`system_will_sleep`, `mouse.entered`, `mouse.exited`, `mouse.clicked`,
`mouse.scrolled`, `volume_change`, `power_source_change`, `battery_change`,
`wifi_change`, `system_stats`, `mouse.exited.global`, `mouse.entered.global`,
`modifier_change`, `app_launched`, `app_terminated`, `media_change`,
`bluetooth_change`, `bluetooth_pair`. The last two are Windows-only.

When a tiling WM is detected (and `reserve` is not `off`/`appbar`) the daemon
registers `komorebi_workspace_change` (fired for komorebi and YTile alike)
and, under YTile, `ytile_workspace_change` as well. `space_change` fires
alongside them with the same variables.

Providers arm on first subscription, so a config that never mentions an event
pays nothing for it. Scripts receive `NAME`, `SENDER`, `INFO`, and any
event-specific variables (`FOCUSED_WORKSPACE`, `MEDIA_TITLE`, `CPU_USAGE`,
`MODIFIER`, ...).

### Windows-specific behavior

- **SSID.** Windows 11 24H2 gates the SSID behind the Location privacy
  setting. Without it, `wifi_change` reports `"connected"` instead of the
  network name, the same degradation macOS has without Core Location.
  `ybar --bar wifi_ssid_prompt=on` opens the privacy page.
- **Media.** `media_change` comes from the system media transport controls, so
  it covers Spotify, browsers, and anything else that registers a session, a
  superset of the macOS implementation. `MEDIA_APP` carries the session's app
  id, not a friendly name.
- **App lifecycle.** With komorebi or YTile these events are window-scoped.
  With neither, ybar falls back to a 2 s process snapshot diff, so background
  processes with no UI also appear.
- **Elevated windows.** A non-elevated process's low-level hooks do not see
  input delivered to elevated windows, so popup auto-close and
  `modifier_change` go quiet while an elevated app has focus.
- **Volume, tray, and windows.** `ybar --volume <0-100> [app]` sets the
  master volume, or one app's session group when given an `id` from
  `ybar --query audio`. `ybar --query tray` lists notification-area icons
  and `ybar --tray <name> invoke|close` activates or closes one.
  `ybar --query windows` lists running app windows with their `hwnd`, and
  `ybar --window <hwnd> close|kill` posts `WM_CLOSE` to one or terminates
  its process. All are Windows extensions; the macOS build rejects them.
- **Bluetooth.** `ybar --query bluetooth` returns `{"radio": ..., "scanning":
  ..., "devices": [...]}`. `radio` is `on`, `off`, `disabled`, `unknown` or
  `none` (no radio). Each device has `id`, `name`, `address`, `kind`
  (`classic` or `le`), `can_pair`, `connectable`, `paired`, `connected` and,
  when the stack reports RSSI, `signal`. `ybar --bluetooth scan on|off`
  starts or stops discovery of unpaired devices; a scan also stops itself
  after 60 s. `ybar --bluetooth pair <id>` starts a confirm-only pairing.
  `bluetooth_change` fires when the nearby list changes and carries no
  `INFO`; read the list back with the query. `bluetooth_pair` reports the
  outcome. `INFO` and `BT_STATUS` hold the status (`paired`,
  `already_paired`, `authentication_timeout`, ...). `BT_ID` names the device,
  `BT_PAIRED` is `on` or `off`, and `BT_CEREMONY` names what the device
  asked for. `BT_NEEDS_SETTINGS` is `on` when the device wants a PIN
  ceremony; send the user to `ms-settings:bluetooth` for that.

## Porting a macOS config

The grammar, property paths, event names and Lua API are shared; each side
adds a few platform names. What changes:

| macOS | Windows |
|---|---|
| `sf:` SF Symbols | resolved against Segoe Fluent Icons; most common names map, unmapped ones draw a placeholder and warn once |
| `x-apple.systempreferences:` links | `ms-settings:` URIs (`ms-settings:sound`, `ms-settings:network-wifi`, `ms-settings:batterysaver`) |
| `osascript` media/volume snippets | unnecessary; media and volume are native providers |
| `--volume +N`/`-N` (relative) | absolute `--volume <0-100>` only |
| `--app <pid\|bundle-id> activate\|hide\|quit\|kill` | `--window <hwnd> close\|kill`, with an `hwnd` from `--query windows` |
| `alias` items (menu-bar extras) | not supported; `--add alias` returns an error |
| bar-level glass (the Liquid Glass strip) | DWM Acrylic on the bar window, off whenever Windows' Transparency effects are off, so the shipped theme leaves it off |
| per-item `glass` pills, popup glass | a Mica wallpaper backdrop under the pill or the popup panel (Windows 11 compositor), tinted by its own translucent fill, plus the shader's lit rim; a glass popup row gets its own; Liquid Glass refraction is not reproduced |

## Help

`ybar status` names the log the bar writes (`%LOCALAPPDATA%\ybar\stderr.log`).
Start the daemon with `YBAR_DEBUG=1` set and it traces its bring-up,
surface/DPI geometry and per-frame render statistics to stderr; attach that
to a bug report. Bugs and questions go to
https://github.com/NineFiveB/YBar/issues and security reports follow
https://github.com/NineFiveB/YBar/blob/main/SECURITY.md

## Building

This code lives on the `windows` branch of the YBar repository: an orphan
branch with its own root history that never merges with `main`. Check it out
next to the macOS tree with `git worktree add ..\ybar-win windows`.

Requires Visual Studio 2022 C++ tools, CMake 3.25 or later (the presets file
is schema version 6), Ninja (the presets' generator), and
[vcpkg](https://github.com/microsoft/vcpkg) with `VCPKG_ROOT` set. The engine
is C++20 on Direct3D 11 and Windows.UI.Composition, linked statically
(`x64-windows-static`).

```powershell
cmake --preset default
cmake --build --preset default
ctest --preset default
```

The `release` preset builds the release binary without tests into
`build-release`. Source-tree map:
[docs/WINDOWS-PORT.md §4](https://github.com/NineFiveB/YBar/blob/windows/docs/WINDOWS-PORT.md)
and the `README.md` in each `src/` module directory (`launcher/`, a single
file, has none).

## License

GPL-3.0-only, same as YBar. komorebi is a separate program under its own
license; ybar only communicates with it over its socket and neither links
nor redistributes any komorebi code.
