# jsonc-demo

The declarative config tier: point `-c` at a `.jsonc` file and get a bar with
no Lua at all. `ybar.jsonc` here builds a clock and a battery on the right,
grouped under one bracket background — deliberately small, because its job is
to show the whole schema rather than to be a theme.

Every entry translates into the same commands a CLI client sends, so setter
semantics, the property namespace and the event names are identical to the
other two surfaces. Nothing is interpreted twice.

## Schema

Four top-level keys, all optional. Anything else warns on stderr and is
ignored, so a misspelled section does not silently produce an empty bar.

| Key | Becomes | Notes |
|---|---|---|
| `bar` | `--bar` | object of properties |
| `defaults` | `--default` | the prototype copied into every later item |
| `events` | `--add event <name>` | array of strings |
| `items` | see below | array, created in order |

Each entry in `items` needs a `name`, and then either:

- `bracket`: a non-empty array of member names, which emits
  `--add bracket <name> <members...>`; or
- `position`, which emits `--add item <name> <position>`. The tokens are
  `left`, `right`, `center` (or `c`), `q`/`center_left`, `e`/`center_right`,
  and `popup.<host>` to place the item inside another item's popup. Default
  `left`.

Both forms also accept `props` (an object, emitted as `--set`) and
`subscribe` (a non-empty array of event names, emitted as `--subscribe`).
Unknown keys inside an item warn the same way.

Property keys are the **full dotted sketchybar namespace** — `icon.color`,
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

## Run

```sh
ybar -c examples/jsonc-demo/ybar.jsonc      # or: scripts/ybar-theme use jsonc-demo
```

`ybar-theme` treats any directory holding a `ybarrc.lua`, `ybar.jsonc` or
`ybarrc.jsonc` as a theme, which is why this one is selectable alongside the
Lua themes.
