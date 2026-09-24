# YBar

A GPU-rendered, scriptable status bar for macOS. This is the macOS development branch; the full README is on main.

## Build (macOS)

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

**Themes**: ship-selectable presets — `ybar theme list|current|use <name>|reset|install <git-url>` (`use` re-points a running bar in place through `--reload <path>`, and config discovery honours the choice on every later start; `scripts/ybar-theme` remains as a shim for a source checkout). See [docs/THEMES.md](docs/THEMES.md) for the gallery (Liquid Glass flagship, the darxk Waybar replication, and more) and how to publish your own. [examples/yabai-skhd](examples/yabai-skhd) has the yabai signal recipes (instant window-level updates; the CLI folds `$YABAI_*` signal vars into `--trigger` env) and an skhd setup driving the bar's hotkey-mode indicator pill.
