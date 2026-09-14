# jsonc-demo

The declarative config tier: a clock and a battery module in **JSONC** —
JSON with `//` and `/* */` comments and trailing commas — and no Lua at all.

Point `-c` at a `.jsonc` file and the engine translates it through the same
command layer the CLI uses: `"bar"` → `--bar`, `"defaults"` → `--default`,
`"events"` → `--add event`, and each item → `--add` / `--set` /
`--subscribe`. Property keys are the full dotted sketchybar namespace, so
anything the CLI can set, this can set.

Use it when a bar is a fixed layout plus a few scripts. Reach for Lua
(`examples/darxk`) once modules need logic, state, or in-process event
handlers.

Values translate predictably: strings pass through verbatim (colors as
`0xAARRGGBB` strings), numbers stay numbers, and booleans become `on`/`off`.

## Helpers and permissions

None. `ybar.jsonc` shells out only to `date` for the clock; the battery
module rides the engine's own `power_source_change` events.

## Run

```sh
ybar --config examples/jsonc-demo/ybar.jsonc
```
