# Extending YBar — capabilities for widget & theme authors

This is the developer's-eye view of what the engine gives you to build items,
widgets, popups, and themes against. If you want to *use* YBar, start with the
[README](../README.md); if you want to *build on* it, this is the reference for
the surface area you have to work with.

The contract is [sketchybar](https://github.com/FelixKratz/SketchyBar)'s: items
are live objects driven over IPC, addressed by name, with a stable property
namespace and event model. Anything you can express in a shell script you can
express in Lua (in-process) or over the CLI — see [Config](../README.md#config)
for the three surfaces. The same contract holds on the [Windows
port](WINDOWS-PORT.md); only OS-facing providers and glyph fonts differ.

## Rendering & layout

- Bar window per display (borderless non-activating panel; behind-windows /
  floating / cover-menu-bar levels; all Spaces), menu-bar-autohide aware
  (including the macOS 26 settings location)
- `fullscreen_show=on` keeps the bar visible over **native-fullscreen Spaces** —
  auto-raises above the fullscreen window, restores on regular Spaces (public
  APIs; no SkyLight needed)
- `fullscreen_hide=on` (opt-in) keeps the bar, popups and tooltips **off**
  native-fullscreen Spaces entirely — the WindowServer hides them there, no
  polling; wins over `fullscreen_show`, and without it `topmost=on` still draws
  over fullscreen
- SDF rounded rects (per-corner radii, borders, gradients, shadows), glyph atlas
  with font fallback, color emoji, tinted SF Symbols (`icon=sf:wifi`), ink-precise
  text metrics matching sketchybar's pixel behavior
- `background.shadow.blur` (points, animatable) softens a plate's shadow into a
  falloff; a light shadow colour at distance 0 with a blur is a glow (brackets
  and slider tracks included)
- Five-cursor item layout (`left right center q e`, notch-aware), fixed widths
  with align slack and clipping, `--default` prototypes
- Per-setup notch handling: the `q`/`e` dead zone exists only on physically
  notched displays (`notch_width=0` auto-detects the housing width),
  `notch_offset` drops the bar below the camera on notched screens only,
  `notch_display_height` gives them their own bar height

## Components

- Brackets, anchored popups (auto-close, alignment), graphs, draggable sliders —
  interactive on the bar and inside popups (click + drag deliver `PERCENTAGE`);
  `slider.interactive=off` makes a slider a read-only fill meter (a press is an
  ordinary click; sets still apply)
- **Alias items** — live ScreenCaptureKit captures of other apps' menu bar items
  (`--add alias "App[,Window]"`)
- **Marquee text** (`scroll_texts`), **hover tooltips**, `background.image` +
  `background.clip` cutouts, **idle inhibitor**
- **Arc gauges** — speedometer-style rings with the label centered in the dial
  (`gauge.*`)
- **Images** — `image.string` renders real app icons (`app.<Name>`), SF symbols
  by name (`sf.<symbol>`, immune to PUA codepoint drift), or image files, through
  the atlas color page; `image.desaturate=on` greys one out in the shader and
  `image.y_offset` (animatable) nudges it vertically
- **Popup flow layout** — `popup.wrap_width` wraps members into grids (calendar
  month grids, tile dashboards); blank rows collapse into slim separators
- **Popup fades** — `popup.fade_in` / `popup.fade_out` (frames at 60 Hz, 0 = hard
  cut) ramp the panel's opacity on open and close, same keys as the Windows port

## Scripting & events

- Embedded **Lua 5.4** config runtime (`ybarrc.lua`, in-process, Lua-first event
  dispatch) alongside the shell/CLI contract (`NAME/SENDER/INFO/BUTTON/MODIFIER`
  env)
- Message-scoped `--animate <curve> <frames>` (`linear sin quadratic tanh exp
  circ bounce overshoot`), per-channel color lerp in linear space, `width=dynamic`
  sentinel animation
- Events: mouse enter/exit/click/scroll (+ global exit), `front_app_switched`,
  `space_change`, wake/sleep, `power_source_change`, `volume_change`,
  `wifi_change`, `system_stats`, **`modifier_change`** (live ⌥-held UX),
  **`app_launched` / `app_terminated`**, **`media_change`** (Music/Spotify
  now-playing via distributed notifications — no private MediaRemote; state seeded
  at startup so a bar launched mid-song shows it immediately)
- Native providers: NSWorkspace, IOKit battery, CoreAudio volume, NWPathMonitor,
  in-process CPU/memory stats
- Output volume write path: `ybar --volume <0-100|+N|-N>` / `ybar.volume(pct)`
  (in-process CoreAudio; 0 mutes keeping the level, `"+4"`/`"-4"` step from the
  current level — no more `osascript` per slider tick)
- Running apps, permission-free: `ybar --query apps` → `[{name, bundle_id, pid,
  active, hidden}]` (also `ybar.query_table("apps")` as a Lua table; `apps` is a
  reserved query target like `bar`/`displays`) and `ybar --app <pid|bundle-id>
  activate|hide|quit|kill` — no window titles, so no Screen Recording grant
- AeroSpace integration: the workspace-change hook can invoke `ybar --trigger`
  directly (the CLI folds `$AEROSPACE_FOCUSED_WORKSPACE` from its environment),
  with debounced, generation-guarded refreshes for rapid switching

On Windows the event and provider set maps one-to-one to native equivalents
(WASAPI, GSMTC, `netsh`/WinRT, komorebi/YTile for workspaces) — see
[WINDOWS-PORT.md](WINDOWS-PORT.md).

## Packaging & privacy

- `make app` builds a minimal **app bundle** so the daemon owns its TCC identity —
  Bluetooth, Calendar, and Apple Events prompts attribute to YBar instead of your
  terminal, and grants cover every helper the daemon spawns
- `ybar autostart enable [-c <config>]|disable|status` writes and bootstraps the
  `com.ybar.YBar` LaunchAgent (bundle binary, KeepAlive on crash only, config
  discovered at each start unless pinned)

## Where to start

- Read a real config end to end: [`examples/`](../examples) — the flagship
  `sketchybar-glass` theme, a `yabai-skhd` setup, and a declarative
  `jsonc-demo`.
- Themes ship as selectable presets: `ybar theme list|current|use <name>|reset|
  install <git-url>` (a running bar reloads in place; the choice is honoured by
  config discovery on every start) — see [THEMES.md](THEMES.md) to publish
  your own.
- The engine internals (how items, layout, and rendering fit together) are in
  [ARCHITECTURE.md](ARCHITECTURE.md).
