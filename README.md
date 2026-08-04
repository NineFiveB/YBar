# YBar

**Top bar for macOS** — a GPU-rendered, scriptable status bar. Metal renders everything (SDF shapes, glyph-atlas text, display-link-paced animation at near-zero CPU); the architecture is [sketchybar](https://github.com/FelixKratz/SketchyBar)'s proven live-object model: a single `ybar` binary that is both daemon and CLI client, driven entirely over IPC — plus an embedded Lua runtime so whole configs run in-process.

![YBar in use: AeroSpace workspace pills with live app icons, then the app-menus swap](docs/media/ybar-demo.gif)

*The `sketchybar-glass` theme: workspace pills tracking AeroSpace with live app
icons, a running Claude Code session indicator, CPU graph, and the app-menus
swap replacing the pills in place. The native macOS menu bar is hidden
underneath.*

![Calendar, system monitor and Wi-Fi popups rendered as Liquid Glass panels](docs/media/ybar-popups.gif)

*Popups are first-class items laid out by the same engine: a calendar month
grid (`popup.wrap_width` flow layout), arc gauges for CPU and memory, and a
Settings-style Wi-Fi picker — all on real `NSGlassEffectView` backdrops.
Network names in this recording are placeholders.*

```sh
ybar                                  # start the daemon
ybar --bar height=32 color=0xdd1e1e2e topmost=on
ybar --add item hello left \
     --set hello icon=sf:sparkles label="YBar is alive" \
                 background.drawing=on background.color=0xff313244 \
                 background.corner_radius=8 background.height=24
ybar --animate tanh 45 --set hello label.color=0xfff38ba8   # animated, GPU-paced
ybar --query hello                    # live state as JSON
```

## Why

- Keeps **sketchybar's command grammar and script contract** — existing configs port mechanically, and a pure-Lua compatibility shim runs SbarLua configs nearly verbatim.
- Renders with **Metal**: instanced SDF quads + a CoreText glyph atlas, damage-driven — zero GPU work while the bar is static.
- **100% public APIs** in v1, so macOS updates don't break it.
- On macOS 26+, pills and popups sit on **real Liquid Glass** (`NSGlassEffectView` backdrops — clear for bar pills, frosted for popups); older systems get an in-shader approximation.

## What's here

**Rendering & layout**
- Bar window per display (borderless non-activating panel; behind-windows / floating / cover-menu-bar levels; all Spaces), menu-bar-autohide aware (including the macOS 26 settings location)
- `fullscreen_show=on` keeps the bar visible over **native-fullscreen Spaces** — auto-raises above the fullscreen window, restores on regular Spaces (public APIs; no SkyLight needed)
- SDF rounded rects (per-corner radii, borders, gradients, shadows), glyph atlas with font fallback, color emoji, tinted SF Symbols (`icon=sf:wifi`), ink-precise text metrics matching sketchybar's pixel behavior
- Five-cursor item layout (`left right center q e`, notch-aware), fixed widths with align slack and clipping, `--default` prototypes
- Per-setup notch handling: the `q`/`e` dead zone exists only on physically notched displays (`notch_width=0` auto-detects the housing width), `notch_offset` drops the bar below the camera on notched screens only, `notch_display_height` gives them their own bar height

**Components**
- Brackets, anchored popups (auto-close, alignment), graphs, draggable sliders
- **Alias items** — live ScreenCaptureKit captures of other apps' menu bar items (`--add alias "App[,Window]"`)
- **Marquee text** (`scroll_texts`), **hover tooltips**, `background.image` + `background.clip` cutouts, **idle inhibitor**
- **Arc gauges** — speedometer-style rings with the label centered in the dial (`gauge.*`)
- **Images** — `image.string` renders real app icons (`app.<Name>`), SF symbols by name (`sf.<symbol>`, immune to PUA codepoint drift), or image files, through the atlas color page
- **Popup flow layout** — `popup.wrap_width` wraps members into grids (calendar month grids, tile dashboards); blank rows collapse into slim separators

**Scripting & events**
- Embedded **Lua 5.4** config runtime (`ybarrc.lua`, in-process, Lua-first event dispatch) alongside the shell/CLI contract (`NAME/SENDER/INFO/BUTTON/MODIFIER` env)
- Message-scoped `--animate <curve> <frames>` (`linear sin quadratic tanh exp circ bounce overshoot`), per-channel color lerp in linear space, `width=dynamic` sentinel animation
- Events: mouse enter/exit/click/scroll (+ global exit), `front_app_switched`, `space_change`, wake/sleep, `power_source_change`, `volume_change`, `wifi_change`, `system_stats`, **`modifier_change`** (live ⌥-held UX), **`app_launched` / `app_terminated`**, **`media_change`** (Music/Spotify now-playing via distributed notifications — no private MediaRemote)
- Native providers: NSWorkspace, IOKit battery, CoreAudio volume, NWPathMonitor, in-process CPU/memory stats
- AeroSpace integration: the workspace-change hook can invoke `ybar --trigger` directly (the CLI folds `$AEROSPACE_FOCUSED_WORKSPACE` from its environment), with debounced, generation-guarded refreshes for rapid switching

**Packaging & privacy**
- `make app` builds a minimal **app bundle** so the daemon owns its TCC identity — Bluetooth, Calendar, and Apple Events prompts attribute to YBar instead of your terminal, and grants cover every helper the daemon spawns

## Install

```sh
brew tap AltimG/ybar https://github.com/AltimG/YBar.git
brew install --HEAD ybar
```

See [docs/INSTALL.md](docs/INSTALL.md) for the release-zip route, first-run privacy-permission walkthrough, stable local signing (keeps TCC grants across rebuilds), and login autostart.

## Planned

Space→item association (SkyLight) · per-display `hidden` · `font.features` · `popup.topmost` · media artwork in the now-playing popup · taskbar (window list) example widget.

## Build

Runs on macOS 14+. Building needs a Swift 6 toolchain; the Liquid Glass
backdrops additionally need the macOS 26 SDK (Xcode 26 / CLT 26) — on older
toolchains they compile out and the blur fallback carries the look. Shaders
compile at runtime, so Command Line Tools are enough — full Xcode is not
required.

```sh
make build       # swift build (scratch path outside iCloud-synced dirs)
make test
make app         # ~/Applications/YBar.app — the recommended way to run the daemon
open -g ~/Applications/YBar.app --args -c <your ybarrc.lua>
```

## Config

Three surfaces, mixable at will:

- **Lua**: point the daemon at a `ybarrc.lua`; it runs inside the daemon with an `ybar.*` API (items as live objects, closures as event handlers, `animate`/`exec`/`delay`), plus a sketchybar-compatibility shim exposing the `sbar` API for existing SbarLua configs.
- **CLI**: any shell script or REPL can drive the same live-object model over the socket at runtime — the bar is not a parsed file.
- **JSONC**: point `-c` at a `.jsonc` file for a declarative bar — comments and trailing commas allowed, translated through the same command layer ([example](examples/jsonc-demo/ybar.jsonc)).

The example config's workspace pills speak both **AeroSpace** and **yabai** (native macOS Spaces) and pick the one actually running — the two can coexist installed side by side; see [examples/yabai-skhd](examples/yabai-skhd) for the yabai/skhd setup, including what needs yabai's scripting addition and what works without it.

**Themes**: ship-selectable presets — `scripts/ybar-theme list|use <name>|install <git-url>`. See [docs/THEMES.md](docs/THEMES.md) for the gallery (Liquid Glass flagship, the darxk Waybar replication, and more) and how to publish your own. [examples/yabai-skhd](examples/yabai-skhd) has the yabai signal recipes (instant window-level updates; the CLI folds `$YABAI_*` signal vars into `--trigger` env) and an skhd setup driving the bar's hotkey-mode indicator pill.

## Acknowledgments

YBar stands on the shoulders of [sketchybar](https://github.com/FelixKratz/SketchyBar) by [Felix Kratz](https://github.com/FelixKratz) — the daemon/CLI live-object architecture, the command grammar, and the script contract all originate there, and YBar deliberately stays compatible with them (including the [SbarLua](https://github.com/FelixKratz/SbarLua) API surface). [Waybar](https://github.com/Alexays/Waybar) shaped the feature set — tooltips, the idle inhibitor, and the general "bar as a first-class desktop component" sensibility are its influence.

## License

[GPL-3.0](LICENSE). Copyright (C) 2026 AltimG. Vendored third-party code is
credited in [THIRD_PARTY.md](THIRD_PARTY.md).
