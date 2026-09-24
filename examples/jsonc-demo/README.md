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

## Schema

Four top-level keys, all optional. Anything else warns on stderr and is
ignored, so a misspelled section does not silently produce an empty bar.

| Key | Becomes | Notes |
|---|---|---|
| `bar` | `--bar` | object of properties |
| `defaults` | `--default` | the prototype copied into every later item |
| `events` | `--add event <name>` | array of strings |
| `items` | `--add` / `--set` / `--subscribe` | array of item objects (shape below), created in order |

Each entry of `items` is an object with these keys. Anything else warns on
stderr (`[?] jsonc: items[N]: unknown key …`) and is ignored; a key of the
wrong type is an error that names the entry, and the whole file is rejected.

| Key | Becomes | Notes |
|---|---|---|
| `name` | the item's (or bracket's) name | required, non-empty string |
| `position` | `--add item <name> <position>` | `left` (the default when absent), `right`, `center`, `q` or `e` (or the aliases `l`, `r`, `c`, `center_left`, `center_right`); must be a string when present; unused on a bracket |
| `bracket` | `--add bracket <name> <members…>` in place of `--add item` | non-empty array of member names |
| `props` | `--set <name> key=value …` | object; keys emitted in sorted order |
| `subscribe` | `--subscribe <name> <events…>` | non-empty array of event names |

```jsonc
{
  "name": "clock",
  "position": "right",
  "props": { "icon": "sf:clock", "update_freq": 10,
             "script": "ybar --set \"$NAME\" label=\"$(date '+%H:%M')\"" },
  "subscribe": ["system_woke"],
},
```

`ybar.jsonc` beside this file has a bracket entry as well.

Property keys within items use the full dotted namespace —
`label.font`, `background.corner_radius`, `icon.color.alpha` — exactly as on
the command line. Values coerce predictably: strings pass through verbatim
(colors are `"0xAARRGGBB"` strings, since JSON has no hex literals), booleans
become `on`/`off`, whole numbers stay whole (`10`, never `10.0`, which
integer-typed properties reject), and anything that is not a string, number or
boolean is an error rather than a warning.

JSONC on top of JSON means `//` and `/* */` comments and trailing commas, both
stripped before parsing and both ignored inside string literals. Property keys
within one object are emitted in sorted order, so the generated commands are
deterministic. An implicit `--update` runs once the file is applied, which is
what populates subscription-driven items that have no `update_freq`.

## What it cannot do

This tier is a translation layer, not a language: no expressions, no
conditionals, no closures as event handlers. Handlers are shell strings in
`script`, receiving the usual `$NAME`/`$SENDER`/`$INFO` environment. When a
config needs logic, move to `ybarrc.lua` and the Lua tier — the two use the
same underlying model, so items defined either way behave identically.

## Helpers and permissions

None. `ybar.jsonc` shells out only to `date` for the clock; the battery
module rides the engine's own `power_source_change` events.

## Run

```sh
ybar -c examples/jsonc-demo/ybar.jsonc
# or: ybar --config examples/jsonc-demo/ybar.jsonc
```
