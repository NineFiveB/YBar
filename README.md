# YBar

**Top bar for macOS** — a GPU-rendered, scriptable status bar. Metal renders everything (SDF shapes, glyph-atlas text, 120 Hz animations at near-zero CPU); the architecture is sketchybar's proven live-object model: a single `ybar` binary that is both daemon and CLI client, driven entirely over IPC.

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
- **YBar** keeps sketchybar's command grammar and script contract (configs port mechanically), renders with Metal (instanced SDF quads + CoreText glyph atlas, damage-driven — zero GPU work while static), and uses **100% public APIs** in v1 so macOS updates don't break it.

See [docs/VISION.md](docs/VISION.md) and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full design, and [docs/BUILDING.md](docs/BUILDING.md) for build notes.

## Status

Early but real — the core loop works end-to-end:

- Bar window per display (borderless non-activating panel; behind-windows / floating / cover-menu-bar levels; all Spaces; over fullscreen)
- Metal renderer: SDF rounded rects (per-corner radii, borders, gradients, hard shadows), glyph atlas with font fallback, color emoji, tinted SF Symbols (`icon=sf:wifi`)
- Item model: icon/label/backgrounds, five-cursor layout (`left right center q e`, notch-aware), fixed widths, `--default` prototypes
- IPC + CLI: `--bar --default --add --set --subscribe --trigger --animate --update --query --remove --reload --hotload` over a unix socket, sketchybar wire format
- Animation: message-scoped `--animate <curve> <frames>`, curves `linear sin quadratic tanh exp circ` **plus working `bounce`/`overshoot`**, per-channel color lerp in linear space, display-link-paced
- Events + scripts: `NAME/SENDER/INFO/BUTTON/MODIFIER` env contract, `update_freq` polling, custom events bound to distributed notifications, hover/click/scroll routing
- Native providers: front app / space / wake / sleep (NSWorkspace), battery with real percentage (IOKit), volume (CoreAudio), network (NWPathMonitor)
- Brackets, popups, graphs, sliders · Lua config (SbarLua-style) · AeroSpace/yabai workspaces · alias items via ScreenCaptureKit · signed .app + brew cask

## Build

Requires macOS 14+ and a Swift 6 toolchain. Shaders compile at runtime, so Command Line Tools are enough — full Xcode is not required.

```sh
make build       # swift build with a scratch path outside iCloud (see docs/BUILDING.md)
make test
make run
```

## Config

The config is an executable script (`~/.config/ybar/ybarrc`) that talks to the daemon through the CLI — see [examples/ybarrc](examples/ybarrc). Everything a config can do, a plugin script or your shell can do at runtime; the bar is a live object model, not a parsed file.

## License

TBD.
