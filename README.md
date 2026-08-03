# YBar

**Top bar for macOS** — a GPU-rendered, scriptable status bar. Metal renders everything (SDF shapes, glyph-atlas text, display-link-paced animation at near-zero CPU); the architecture is [sketchybar](https://github.com/FelixKratz/SketchyBar)'s proven live-object model: a single `ybar` binary that is both daemon and CLI client, driven entirely over IPC — plus an embedded Lua runtime so whole configs run in-process.

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
- SDF rounded rects (per-corner radii, borders, gradients, shadows), glyph atlas with font fallback, color emoji, tinted SF Symbols (`icon=sf:wifi`), ink-precise text metrics matching sketchybar's pixel behavior
- Five-cursor item layout (`left right center q e`, notch-aware), fixed widths with align slack and clipping, `--default` prototypes

**Components**
- Brackets, anchored popups (auto-close, alignment), graphs, draggable sliders
- **Arc gauges** — speedometer-style rings with the label centered in the dial (`gauge.*`)
- **Images** — `image.string` renders real app icons (`app.<Name>`), SF symbols by name (`sf.<symbol>`, immune to PUA codepoint drift), or image files, through the atlas color page
- **Popup flow layout** — `popup.wrap_width` wraps members into grids (calendar month grids, tile dashboards); blank rows collapse into slim separators

**Scripting & events**
- Embedded **Lua 5.4** config runtime (`ybarrc.lua`, in-process, Lua-first event dispatch) alongside the shell/CLI contract (`NAME/SENDER/INFO/BUTTON/MODIFIER` env)
- Message-scoped `--animate <curve> <frames>` (`linear sin quadratic tanh exp circ bounce overshoot`), per-channel color lerp in linear space, `width=dynamic` sentinel animation
- Events: mouse enter/exit/click/scroll (+ global exit), `front_app_switched`, `space_change`, wake/sleep, `power_source_change`, `volume_change`, `wifi_change`, `system_stats`, **`modifier_change`** (live ⌥-held UX), **`app_launched` / `app_terminated`**
- Native providers: NSWorkspace, IOKit battery, CoreAudio volume, NWPathMonitor, in-process CPU/memory stats
- AeroSpace integration: the workspace-change hook can invoke `ybar --trigger` directly (the CLI folds `$AEROSPACE_FOCUSED_WORKSPACE` from its environment), with debounced, generation-guarded refreshes for rapid switching

**Packaging & privacy**
- `make app` builds a minimal **app bundle** so the daemon owns its TCC identity — Bluetooth, Calendar, and Apple Events prompts attribute to YBar instead of your terminal, and grants cover every helper the daemon spawns

## Planned

SkyLight opt-in surface (bar over native-fullscreen Spaces) · media/now-playing widget · alias items via ScreenCaptureKit · stable signing + Homebrew cask · yabai adapter · JSONC config tier.

## Build

Requires macOS 14+ and a Swift 6 toolchain. Shaders compile at runtime, so Command Line Tools are enough — full Xcode is not required.

```sh
make build       # swift build (scratch path outside iCloud-synced dirs)
make test
make app         # ~/Applications/YBar.app — the recommended way to run the daemon
open -g ~/Applications/YBar.app --args -c <your ybarrc.lua>
```

## Config

Two equivalent surfaces, mixable at will:

- **Lua**: point the daemon at a `ybarrc.lua`; it runs inside the daemon with an `ybar.*` API (items as live objects, closures as event handlers, `animate`/`exec`/`delay`), plus a sketchybar-compatibility shim exposing the `sbar` API for existing SbarLua configs.
- **CLI**: any shell script or REPL can drive the same live-object model over the socket at runtime — the bar is not a parsed file.

## Acknowledgments

YBar stands on the shoulders of [sketchybar](https://github.com/FelixKratz/SketchyBar) by [Felix Kratz](https://github.com/FelixKratz) — the daemon/CLI live-object architecture, the command grammar, and the script contract all originate there, and YBar deliberately stays compatible with them (including the [SbarLua](https://github.com/FelixKratz/SbarLua) API surface). [Waybar](https://github.com/Alexays/Waybar) shaped the feature set — tooltips, the idle inhibitor, and the general "bar as a first-class desktop component" sensibility are its influence.

## License

[GPL-3.0](LICENSE).
