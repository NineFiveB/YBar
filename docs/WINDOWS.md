# YBar on Windows

YBar has a native Windows 11 port. It is a separate C++ engine on the
[`windows` branch](../../../tree/windows), an orphan branch with its own
toolchain, CI and release cadence. It speaks the same command grammar, the
same socket protocol and the same embedded Lua 5.4 API as the macOS engine,
so themes, configs and shell scripts carry over with only the OS-specific
bits changed: the shell commands they run, the glyph fonts, and the window
manager adapter.

[WINDOWS-PORT.md](WINDOWS-PORT.md) is the design document and the platform
contract between the two engines. The branch's own
[README](../../../blob/windows/README.md) has the source-tree map, the full
porting table and the packaging details. This page is the short version:
what to install, what is native, and what the GIFs show.

To check the branch out beside the macOS tree:

```powershell
git worktree add ..\ybar-win windows
```

## Requirements

Windows 11, 22H2 or later. Windows 10 is untested.

## Install

Three channels. All of them put `ybar` on your `PATH`.

**PowerShell, one line, no admin rights:**

```powershell
irm https://raw.githubusercontent.com/NineFiveB/YBar/windows/scripts/install.ps1 | iex
```

The script downloads the latest signed `win-v*` release into
`%LOCALAPPDATA%\Programs\ybar`, checks the SHA256 the release publishes and
the Authenticode signature, and adds the directory to your `PATH`.
Environment variables steer it: `$env:YBAR_START=1` launches the bar when
done, `$env:YBAR_AUTOSTART=1` registers it to run at login,
`$env:YBAR_VERSION=0.1.0` pins a version, and `$env:YBAR_UNINSTALL=1`
removes it with the same one-liner. Uninstall leaves `~\.config\ybar` alone.

**Scoop:**

```powershell
scoop install https://raw.githubusercontent.com/NineFiveB/YBar/windows/packaging/scoop/ybar-win.json
```

The shim lands on your `PATH` as `ybar`, and `scoop update ybar-win` follows
new releases.

**Release zip:** download `ybar-win-<version>-x64.zip` from a
[`win-v*` release](../../../releases) and unpack it anywhere. It is
self-contained: `ybar.exe`, `ybarw.exe` (a windowless launcher that runs
`ybar start` with no console, for shortcuts and schedulers), the shader the
engine compiles at runtime, the shipped themes and an app-local
`d3dcompiler_47.dll`. Put the folder on your `PATH` so config scripts can
call `ybar` back.

Release binaries are Authenticode-signed through Azure Trusted Signing in
CI. SmartScreen may still warn until the certificate accrues reputation. A
winget manifest is staged under `packaging/` on the `windows` branch for
submission; it is not published yet.

Then the same verbs as on the Mac:

```powershell
ybar start               # launch the bar in the background, no console window
ybar autostart enable    # run at every login (an HKCU Run entry; shows in Task Manager > Startup apps)
ybar status              # bar, config and autostart state
ybar stop                # stop it; ybar restart [-c <path>] stops and relaunches
ybar theme use sketchybar-glass
```

A bar started this way writes its stderr to `%LOCALAPPDATA%\ybar\stderr.log`,
rotated at 1 MB; `ybar status` names it.

## What it looks like

![The Windows bar: workspace pills tracking komorebi or YTile, with CPU and battery fill meters and the tray widget](media/ybar-win-bar.gif)

*The `sketchybar-glass` theme on Windows 11, restyled to Fluent: workspace
pills tracking the active YTile or komorebi workspace (under YTile, empty
workspaces hide their pills), the CPU and battery pills as continuous fill
meters, and the notification-area tray widget. The strip itself is flat and
near-black, with no Acrylic of its own; the material lives on the pills
instead, as below. Recorded before Mica landed.*

![Windows popups: system monitor, Wi-Fi, Bluetooth, calendar, battery and tray flyouts](media/ybar-win-popups.gif)

*Popups are ordinary items laid out by the same engine: a Task Manager-style
system monitor with live CPU and GPU graphs, Fluent Wi-Fi and Bluetooth
flyouts (the Bluetooth one carries the system volume mixer; a drag sets the
output volume through the daemon itself), a calendar month grid, a battery
panel, and the tray widget, where a left click opens an app and a right
click quits it behind a confirm. Network and device names in this recording
are placeholders.*

## Materials: Mica and Acrylic

Item-level `background.glass` on Windows is **Mica**: a blurred-wallpaper
visual composed under the pill by the window's own Windows.UI.Composition
tree, tinted by the pill's own translucent fill, with the shader's lit rim
on top. The shipped theme turns it on for the widget pills, the calendar,
the focused workspace pill and the popup panels.

![Mica pills: the widget pills switch between a flat fill and a wallpaper material with a lit rim](media/ybar-win-mica.gif)

*The same pills with `background.glass` toggled off and on. The material is
the desktop wallpaper, blurred and sampled in screen space: a pill shows the
patch of wallpaper it sits over, not the windows in between, and its own
fill is only the tint. On a wallpaper that is flat under the strip, as here,
the pills read as a lighter gray rather than as texture. Popup panels get
the same treatment across the whole panel; their rows stay flat, though a
row can cut its own window through the panel on the same gate a pill uses.*

Two things follow from where the material comes from. It needs the Windows
11 compositor, and it renders whether or not the system's Transparency
effects setting is on. Bar-level `glass` is different: it maps to DWM
Acrylic, which that setting switches off. The shipped theme leaves bar-level
glass off anyway, so the pills have a flat strip to stand against. And Mica
is not Liquid Glass: it does not refract, so the rim is what gives a pill
its edge.

## Depth effects (opt-in)

The engine can also lift and glow these pills. The shipped theme lights them
but leaves these two effects off. Glow is one flag away in Lua, `FOCUS_HALO`
in `items/spaces.lua`; elevation is a one-line swap in `helpers/hover.lua`.
All three GIFs below were recorded before Mica landed, by driving the same
`--animate` path a real hover takes, so no cursor is in frame.

![Hover elevation: a pill lifts a point and gains a top-lit gradient as the pointer arrives, and settles back as it leaves](media/ybar-win-depth-hover.gif)

*Hover elevation: `background.y_offset` plus a two-stop `gradient_color`
under the hover fill (`helpers/hover.lua`, `attachRaised`). Nothing moves as
far as input is concerned, so the hit rect stays exact.*

![Bevel lighting: every pill's rim switches from flat to a quarter-round edge lit from above, highlight on the top arc and shade under the bottom](media/ybar-win-depth-bevel.gif)

*Bevel lighting: the rim half of `background.glass`. The shader builds a
real surface normal from the rounded-box SDF and shades it Blinn-Phong. The
rim costs no extra draw. Today the same property also composes the Mica
material above.*

![Glow: a soft white halo sweeps from pill to pill](media/ybar-win-depth-glow.gif)

*Glow: `background.shadow.blur` with a light color at zero offset. The same
soft-falloff quad is a drop shadow with a dark color; either way the 112-byte
instance layout shared with macOS is untouched. It sits one flag from the
focused-workspace halo and ships off, because the focused pill already reads
as the Mica one.*

## What is native on Windows

- **Engine.** Direct3D 11 with a DirectWrite glyph atlas, HLSL compiled at
  runtime, and Windows.UI.Composition carrying the Mica layer
  (DirectComposition survives only as the frame clock). Paced to the
  monitor's refresh rate, near-zero CPU while static. The GPU instance
  layout is shared byte-for-byte with macOS except for the hole struct. It
  is the Metal engine's mirror.
- **Window management.** [komorebi](https://github.com/LGUG2Z/komorebi) and
  YTile are the workspace adapters, in place of AeroSpace and yabai. The
  daemon speaks komorebi's socket protocol and YTile's named pipe directly
  and reserves its strip through them, driven by their event streams rather
  than by polling a CLI. komorebi outranks when both are present. The
  shipped theme's pills subscribe to `komorebi_workspace_change`, which both
  paths fire.
- **Native providers.** Battery and power, audio (WASAPI; `--volume` can
  also target one app's session), network and Wi-Fi (`wlanapi` plus
  connectivity-hint notifications; the Wi-Fi flyout's network list shells
  `netsh`), now-playing media (GSMTC), in-process CPU and memory stats, tray
  icons and a foreground hook for `front_app_switched`, all mapped to the
  same event names as macOS.
- **Look.** The flagship `sketchybar-glass` theme is ported and restyled to
  Windows 11 Fluent: Mica pills and popup panels over a flat near-black
  strip, and Fluent Wi-Fi, Bluetooth, system-monitor and calendar popups.
  `catppuccin-komorebi` is a declarative JSONC bar.
- **Grammar extensions.** Windows adds `--komorebi`, `--tray`, `--window`, a
  per-app second token on `--volume`, and `--query windows|tray|audio`. The
  `alias` component (menu-bar-extra capture) is accepted by the grammar but
  not supported there.

## Porting a macOS config

The grammar, property paths, event names and Lua API are identical. What
changes: `sf:` icon names resolve against Segoe Fluent Icons;
`x-apple.systempreferences:` links become `ms-settings:` URIs; `osascript`
media and volume snippets are unnecessary because both are native providers;
`alias` items are not supported; per-item glass is Mica rather than Liquid
Glass. Scripts run under `sh` (Git Bash on `PATH`, or Git for Windows'
`sh.exe` found through the registry), else PowerShell; `YBAR_SHELL`
overrides. The branch README has the full table.

## Build

Windows 11 22H2 or later, Visual Studio 2022 C++ tools, CMake 3.25 or later,
and [vcpkg](https://github.com/microsoft/vcpkg) with `VCPKG_ROOT` set:

```powershell
cmake --preset default
cmake --build --preset default
ctest --preset default
```

The contract tests are Catch2 ports of the platform-neutral Swift tests.

## Read more

- [WINDOWS-PORT.md](WINDOWS-PORT.md): the port's design and platform contract
- [The `windows` branch README](../../../blob/windows/README.md): source-tree map, porting table, packaging
- [CONFIG.md](CONFIG.md): the config surfaces shared by both engines
