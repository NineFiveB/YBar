# YBar

[![CI](https://github.com/NineFiveB/YBar/actions/workflows/ci.yml/badge.svg)](https://github.com/NineFiveB/YBar/actions/workflows/ci.yml)

**A status bar your GPU draws.** Script it from the shell or from Lua. Runs on macOS and Windows 11.

It does nothing at rest. Your config is Lua running inside it. A sketchybar config ports over with the same commands.

![YBar in use: AeroSpace workspace pills, then the app menus opening in the bar](docs/media/ybar-demo.gif?v=20260922)

*The `ysuite-liquid` theme on macOS: AeroSpace workspace pills, then the app menus opening in the bar and folding back. The stock menu bar is hidden underneath. (The menu swap is an opt-in helper built from a source checkout with `make helpers`; Homebrew does not ship it.)*

![Calendar, system monitor, battery, Wi-Fi and Bluetooth popups on Liquid Glass](docs/media/ybar-popups.gif?v=20260922)

*Five popups, all real glass: calendar, system monitor, battery, Wi-Fi and Bluetooth. Network and device names in this recording are placeholders.*

## Twenty seconds to a live bar

```sh
ybar start
ybar --bar height=32 color=0xdd1e1e2e topmost=on            # covers the stock menu bar; omit to keep it
ybar --add item hello left --set hello icon=sf:sparkles label="YBar is alive"
ybar --animate tanh 45 --set hello label.color=0xfff38ba8   # every change after --animate glides
ybar --query hello                                          # live state as JSON
```

The bar is a set of live objects. Add one, set a property, and it redraws. One binary does both jobs. Run `ybar` and it is the bar. Run it with `--` commands and it is the remote control: a local socket, driven from any shell, script or REPL. Write the whole bar as Lua, as a shell script, or as JSON with comments; it is the same engine underneath ([docs/CONFIG.md](docs/CONFIG.md)). Turn on `--hotload on` and the bar reloads in place when you save your config.

## Why YBar

- **Nothing changes, nothing draws.** There is no draw loop. A frame is drawn only when something changed, so at rest the GPU does no work. When something does move, it moves at your display's refresh rate, up to 120 Hz, and stops the moment it is done. Pills, gradients, shadows and glows are math in a shader, not bitmaps, so they stay sharp at any size on any display.
- **Real Liquid Glass.** On macOS 26 the pills and popups sit on the system's own glass backdrops. macOS 14 and 15 get a blur that looks the part.
- **Hide the stock menu bar and put yours in its place.** `topmost=on` puts the bar above the native one. No SIP changes. Public APIs only, so an OS update should not take it down. The one exception: the Wi-Fi popup reads a single private flag to list saved hotspots; if Apple moves it, that list is empty and nothing else changes ([SECURITY.md](SECURITY.md)).
- **Your sketchybar config ports mechanically.** Same commands, same property names, same JSON from `--query`. `sbar = require("sketchybar")` and most SbarLua configs run nearly unchanged.
- **Your config is Lua and it runs inside the bar.** A click calls your function directly. No socket, no shell, no fork.
- **Popups are just items.** A calendar grid or a Wi-Fi list is more items, drawn by the same engine. Graphs, sliders, arc gauges, app icons, marquees and tooltips are built in.
- **Batteries included.** Battery, volume, Wi-Fi, now-playing, CPU and memory come from the engine itself. Volume, Wi-Fi, now-playing and the stats sampler wake up the first time a widget asks for them; battery is always on and costs nothing. Nothing shells out every second.

## Install

Requirements: macOS 14 or later (Liquid Glass on macOS 26); Windows 11.

### macOS

```sh
brew tap NineFiveB/ybar
brew install ybar           # tagged release; --HEAD builds current main
ybar start
ybar theme use darxk        # any name from `ybar theme list`
```

First install from a third-party tap asks for confirmation; `brew trust NineFiveB/ybar` pre-approves it. `ybar autostart enable` brings the bar back at every login. Privacy prompts say "YBar", not "Terminal", and only the widgets you turn on ask for anything. The full walkthrough is in [docs/INSTALL.md](docs/INSTALL.md).

### Windows 11

One line in PowerShell, no admin rights:

```powershell
irm https://raw.githubusercontent.com/NineFiveB/YBar/windows/scripts/install.ps1 | iex
```

Or with Scoop:

```powershell
scoop install https://raw.githubusercontent.com/NineFiveB/YBar/windows/packaging/scoop/ybar-win.json
```

Then `ybar start`. The release zip and autostart are in [docs/WINDOWS.md](docs/WINDOWS.md).

## Eleven themes, one command

`ybar theme use darxk` switches a running bar in place, no restart; with no bar running it starts one.

- `sketchybar-glass`: the flagship. A near-black Liquid Glass bar with glass pills and popups and the full widget suite.
- `ysuite`: the maintainer's daily driver. The same glass suite, full width, covering the native menu bar edge to edge.
- `ysuite-liquid`: a clear full-bleed strip with glass capsule pills. The theme in the GIFs above.
- `darxk`: a replication of 00Darxk's Waybar setup. The smallest complete Lua theme and the place to start your own.
- `sketchybar-port`: the full sketchybar setup port in its original styling. The tree the flagships layer on.
- `jsonc-demo`: a clock and a battery in JSON with comments. No Lua.
- `nord`: a flat opaque Nord strip. Frost icons, aurora battery colors, thin separators.
- `gruvbox`: retro powerline. Gruvbox segments joined by arrow glyphs.
- `tokyonight`: a floating rounded island in Tokyo Night blues and purples.
- `dracula`: colorful blocks. Every module gets its own bright background.
- `rose-pine`: whisper-minimal. Workspace dots, lowercase text, no backgrounds.

Modules probe for optional tools such as AeroSpace or Homebrew and hide themselves when one is missing, so one config works across machines. Gallery, verbs and how to publish your own: [docs/THEMES.md](docs/THEMES.md).

## The same bar on Windows 11

YBar has a native Windows 11 port on the [`windows` branch](../../tree/windows): a C++ engine on Direct3D 11. It speaks the same commands, the same socket protocol and the same Lua API. Themes, configs and scripts move over with only the OS-specific bits changed: shell commands, glyph fonts, the window manager adapter. Workspace pills follow komorebi or YTile. Pills sit on Mica. Battery, volume, Wi-Fi, media and the tray come from Windows' own APIs under the same event names as the Mac.

![The Windows bar: workspace pills tracking komorebi or YTile, CPU and battery fill meters, the tray widget](docs/media/ybar-win-bar.gif)

*The `sketchybar-glass` theme on Windows 11, restyled to Fluent: workspace pills, CPU and battery pills as fill meters, and the tray widget. Flat pills, recorded before Mica landed.*

Install channels, materials, depth effects and the build: [docs/WINDOWS.md](docs/WINDOWS.md).

## Read more

- [docs/INSTALL.md](docs/INSTALL.md): install, autostart, privacy prompts, signing
- [docs/CONFIG.md](docs/CONFIG.md): Lua, shell, JSONC, workspace adapters
- [docs/THEMES.md](docs/THEMES.md): theme gallery, verbs, publishing yours
- [docs/EXTENDING.md](docs/EXTENDING.md): every property, event and component
- [docs/BUILDING.md](docs/BUILDING.md): toolchain, make targets, test suite
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): renderer, IPC, providers, design rules
- [docs/WINDOWS.md](docs/WINDOWS.md): the Windows 11 port guide
- [docs/WINDOWS-PORT.md](docs/WINDOWS-PORT.md): the Windows port's design and platform contract
- [CHANGELOG.md](CHANGELOG.md): what changed in each release
- [SECURITY.md](SECURITY.md): supported versions, reporting, API scope
- [CONTRIBUTING.md](CONTRIBUTING.md): themes, CI, releases, README GIFs

## Acknowledgments

YBar stands on [sketchybar](https://github.com/FelixKratz/SketchyBar) by [Felix Kratz](https://github.com/FelixKratz). The daemon and CLI architecture, the command grammar and the script contract all come from there, and YBar stays compatible with them, [SbarLua](https://github.com/FelixKratz/SbarLua) included. [Waybar](https://github.com/Alexays/Waybar) shaped the feature set: tooltips, the idle inhibitor and the sense that a bar should come with batteries included.

## License

[GPL-3.0](LICENSE). Copyright (C) 2026 YSuite. Vendored third-party code is credited in [THIRD_PARTY.md](THIRD_PARTY.md).
