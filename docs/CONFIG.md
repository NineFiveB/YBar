# Configuring YBar

YBar has no config format of its own to learn. The bar is a set of live
objects, and every way of configuring it is a way of sending the same
commands to the same engine. Pick one surface or mix them.

## Three surfaces

### Lua, inside the bar

A `ybarrc.lua` runs inside the daemon on the vendored Lua 5.4 runtime. Items
are live objects, closures are event handlers, and a click is a direct
function call: no socket round trip, no shell, no process spawn.

```lua
ybar.bar({ height = 32, color = "0xee1e1e2e" })
local clock = ybar.add("item", "clock", "right")
clock:set({ icon = "sf:clock", update_freq = 10, label = os.date("%H:%M") })
clock:subscribe("routine", function() clock:set({ label = os.date("%H:%M") }) end)
```

The `ybar.*` API: `bar`, `default`, `add`, `set`, `subscribe`, `trigger`,
`push`, `remove`, `update`, `exec`, `delay`, `animate`, `volume`,
`query_table`, `wifi_scan`, `wifi_join`, `wifi_prompt` and
`wifi_disconnect`. Property tables nest (`background = { height = 16 }`) or
use dotted keys (`["icon.color"] = ...`); both flatten onto the same
namespace. [`examples/ybarrc.lua`](../examples/ybarrc.lua) is a complete
small config with comments.

**Porting an SbarLua config.** `sbar = require("sketchybar")` loads a
pure-Lua shim
([`examples/sketchybar-port/sketchybar.lua`](../examples/sketchybar-port/sketchybar.lua))
that exposes the SbarLua `sbar` API on top of the runtime: item handles with
`:set`, `:subscribe`, `:query` and `:push`, plus `sbar.exec` and
`sbar.animate`. Most configs run with minimal edits. The differences:
everything runs in-process, so callbacks are direct calls, and
`begin_config`, `end_config` and `event_loop` are no-ops because the daemon
owns the loop. Every shipped Lua theme goes through this shim.

### The CLI, over the socket

Run `ybar` with `--` commands and it is a thin client: the arguments go to
the running bar over a local socket (`/tmp/ybar_<user>.socket`, owner-only)
and the reply is printed. Any shell script, REPL or language that can write
to a socket can drive the bar at runtime, and one invocation batches many
`--` domains.

The verbs are sketchybar's: `--bar`, `--default`,
`--add item|graph|slider|bracket|event|alias`, `--set`, `--subscribe`,
`--trigger`, `--animate`, `--update`, `--query`, `--push`, `--remove`,
`--move`, `--reorder`, `--rename`, `--clone`, `--reload`, `--hotload`,
`--ping` and `--exit`. YBar adds `--volume` and `--app`. Property names are
sketchybar's dotted namespace (`icon.background.shadow.color.alpha`), colors
are `0xAARRGGBB`, booleans take `on`, `off` and `toggle`, `--query` returns
sketchybar-shaped JSON, and `<name>` in `--set` and `--remove` may be a
`/regex/`. sketchybar's accepted-and-ignored compatibility keys are kept.
`ybar --help` prints the whole grammar.

Scripts get sketchybar's environment, verbatim: `NAME`, `SENDER`, `INFO`,
`BUTTON`, `MODIFIER`, `SCROLL_DELTA`, `PERCENTAGE`, `CONFIG_DIR` and
`BAR_NAME`. `update_freq` polls off a 1 Hz timer. Scripts run under `sh -c`
with the config directory as the working directory and a 60 s watchdog. An
executable `ybarrc` shell config works as-is
([`examples/ybarrc`](../examples/ybarrc)).

### JSON with comments

Point `-c` at a `.jsonc` file for a declarative bar. Comments and trailing
commas are allowed. Four top-level keys, `bar`, `defaults`, `events` and
`items`, carry the same dotted property keys and are translated through the
same command layer. Unknown keys warn; a key of the wrong type rejects the
whole file with a message naming the entry. No expressions, no closures:
handlers are shell strings in `script`.
[`examples/jsonc-demo`](../examples/jsonc-demo/README.md) has the schema and
[`ybar.jsonc`](../examples/jsonc-demo/ybar.jsonc) is the example.

## Where the config comes from

With `-c <path>`, that file. Without it: the theme selected with
`ybar theme use`, then `~/.config/ybar/ybarrc.lua`, `ybarrc`, `ybarrc.jsonc`
and `ybar.jsonc`, then `~/.ybarrc.lua` and `~/.ybarrc`. Dispatch is by
extension: `.lua` runs in the Lua runtime, `.json` and `.jsonc` go through
the translator, anything else is an executable script.
[INSTALL.md](INSTALL.md#first-run) walks through the first run;
[ARCHITECTURE.md](ARCHITECTURE.md#2-process-model--lifecycle) has the exact
rules, `$XDG_CONFIG_HOME` included.

## Reload and hot reload

`ybar --reload` re-runs the current config; `ybar --reload <path>` re-points
a running bar at another one, in place. `ybar --hotload on` watches the
config file and its directory and reloads when you save, with a half-second
debounce. A reload is a full teardown and re-run, not a diff.

## Themes

A theme is a directory with a `ybarrc.lua` (or `ybar.jsonc`, `ybarrc.jsonc`)
entry point. The verbs need no running daemon:

```sh
ybar theme list                # shipped and installed themes; * marks the selected one
ybar theme current             # the selected name
ybar theme use darxk           # a running bar reloads in place; otherwise the bar is started
ybar theme reset               # forget the selection
ybar theme install <git-url>   # clone a community theme into ~/.config/ybar/themes
```

`use` records the choice in `~/.config/ybar/current-theme`, and config
discovery honors it on every later start, the login agent included.
[THEMES.md](THEMES.md) has the gallery, the theme roots, what a pinned `-c`
does to a selection, and how to publish a theme of your own.

## Workspace adapters

Workspace pills are theme-side adapters, not an engine provider. The
engine's own `space_change` event carries no ids, so pills need a window
manager to read from.

**macOS: AeroSpace.** The shipped `items/spaces.lua` (in `sketchybar-port`,
shared by the themes layered on it) talks to the `aerospace` CLI and
subscribes to an `aerospace_workspace_change` event. AeroSpace's
`exec-on-workspace-change` hook can call
`ybar --trigger aerospace_workspace_change` directly, because the CLI folds
`$AEROSPACE_FOCUSED_WORKSPACE` and `$AEROSPACE_PREV_WORKSPACE` from its
environment into the trigger. The shipped themes probe for the binary at
`/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`, and hide the workspace
module when it is missing, so the rest of the theme still works.

**macOS: yabai.** `items/spaces_yabai.lua` reads `yabai -m query --spaces`
for native Spaces. Reading them needs no scripting addition; clicking a
pill to focus a space does. The signal recipes in
[`examples/yabai-skhd`](../examples/yabai-skhd/README.md) make updates
instant, and the CLI folds every `$YABAI_*` variable into `--trigger` the
same way. The example config picks whichever window manager is running and
falls back to whichever is installed. One caveat from that README: on a
macOS 27 beta yabai's tiling did not work even with the scripting addition
loaded, while the space pills kept working.

**Windows: komorebi and YTile.** The Windows daemon has native providers for
both and publishes `komorebi_workspace_change` for either, so one theme
works with both; komorebi outranks when both run. See
[WINDOWS.md](WINDOWS.md).

## Where to go next

- [EXTENDING.md](EXTENDING.md): the full catalog of properties, components,
  events and providers to build widgets against.
- [THEMES.md](THEMES.md): the shipped themes and how to write and share one.
- [`examples/`](../examples): every shipped theme, the small `ybarrc.lua` and
  `ybarrc`, the JSONC demo and the yabai and skhd setup.
