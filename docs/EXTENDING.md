# Extending YBar — capabilities for widget & theme authors

This is the developer's-eye view of what the engine gives you to build items,
widgets, popups, and themes against. If you want to *use* YBar, start with the
[README](../README.md); if you want to *build on* it, this is the reference for
the surface area you have to work with.

The contract is [sketchybar](https://github.com/FelixKratz/SketchyBar)'s: items
are live objects driven over IPC, addressed by name, with a stable property
namespace and event model. Anything you can express in a shell script you can
express in Lua (in-process) or over the CLI — see [CONFIG.md](CONFIG.md)
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
  over fullscreen; `--query bar` reports both flags
- SDF rounded rects (per-corner radii, borders, gradients, shadows), glyph atlas
  with font fallback, color emoji, tinted SF Symbols (`icon=sf:wifi`), ink-precise
  text metrics matching sketchybar's pixel behavior
- `background.shadow.blur` (points, animatable) softens a plate's shadow into a
  falloff; a light shadow colour at distance 0 with a blur is a glow (brackets
  and slider tracks included)
- **Liquid Glass** — `--bar glass=on` puts the strip on a real
  `NSGlassEffectView` backdrop on macOS 26+ (the blur fallback before it);
  `glass_variant=clear|regular` picks the public `NSGlassEffectView.Style`
  (`default`/`off` restore the built-in `clear`) and `glass_tint=<color>`
  tints it, alpha as intensity. Per plate, `background.glass=on` gives a pill
  or popup its own backdrop (an in-shader approximation on 14/15),
  `background.glass_variant` overrides the bar-wide variant for that plate
  and `background.glass_tint` its tint (`default`/`off` — or `0x00000000` for
  the tint — drop the override so the plate inherits the bar's); the same
  `glass`/`sheen`/`glass_tint` keys exist under `popup.background`. `--query`
  reports all of them, `default` where a plate inherits
- `background.sheen=on` (opt-in) is the painted glass highlight — lip, shade
  and a specular that follows the pointer — for macOS 14/15, where the shader
  is the material. It is damage-driven: one frame per pointer move over a
  surface whose scene carries a sheen plate, no display link while the
  pointer rests. On macOS 26 the native glass supplies the highlight and the
  flag is ignored, so no fake shine is drawn over system glass
- `x_offset` (item-level, animatable) slides an item horizontally without
  changing the flow — the next item stays where layout put it, so a pill can
  travel across its neighbors
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
- **Graph styles** — `graph.style=line|bars`: a sparkline, or a vertical
  histogram with a y-axis strip. For either style, `graph.plot_width` (points;
  0 = one point per sample) is the width of the plot box, and the `width`
  samples the graph holds are spread evenly across it — a wider plot
  stretches the line or the bars rather than adding samples. For bars,
  `graph.axis_max` (percent, ≥ 1; 100 is a level plot, 150 matches System
  Settings' 10-day energy chart) sets the top of the axis,
  `graph.tick=<index>|off` draws one under-mark beneath a bar (oldest first)
  and `graph.marks="1 0 1 …"` flags samples in the same order (padded with 0
  to the width; `off` clears) to reserve a below-axis band of charging stubs
  in place of the tick; `--query` reports every one of them
- Slider tracks take a ring: `slider.background.border_color` /
  `border_width` (either turns the track's `drawing` on) and
  `slider.background.drawing` to switch it explicitly — set-only, not in
  `--query`'s `slider` block
- **Alias items** — live ScreenCaptureKit captures of other apps' menu bar items
  (`--add alias "App[,Window]"`, Screen Recording); a click on an alias with no
  script or Lua handler is forwarded to the captured item (Accessibility —
  macOS may prompt on the first click)
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
  cut) ramp the panel's opacity on the window server on open and close: a
  closing panel ignores the mouse, a reopen mid-fade restarts the ramp from 0,
  tooltips keep the hard cut; inherited through `--default popup.*` and
  reported by `--query`; same keys as the Windows port

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
  level the device holds — muted included, so a scroll up resumes where it was
  muted — no more `osascript` per slider tick); in Lua a number is
  absolute and a signed string relative, and the call returns nil or a `[!]`
  string. A number is *always* absolute: `ybar.volume(current - 10)` saturates
  into 0-100 (so an undershoot mutes) and never becomes a step — only the
  string form `"-10"` steps
- **Wi-Fi from Lua**: `ybar.wifi_scan(fn)`, `ybar.wifi_join(ssid, fn)`,
  `ybar.wifi_prompt(ssid, fn)`, `ybar.wifi_disconnect(fn)` (the compat shim
  exposes them as `sbar.wifi_*`), each calling back the way `ybar.exec` does:
  `fn(output, code)`. The scan runs CoreWLAN in-process, off the main thread,
  so the names are readable under YBar's own Location grant rather than a
  child's, and returns TSV, one network per line — `current \t name \t rssi
  \t known \t hotspot \t secure` (1/0 flags; `rssi=-999` is a saved personal
  hotspot that is not broadcasting) — the joined network first, then by
  signal. Code 3 means macOS withheld every SSID until YBar holds the Location
  grant ([INSTALL.md](INSTALL.md#permissions)); only the joined network is
  listed then, as `<redacted>`. `wifi_join` goes through `networksetup` with
  the keychain password (which is what wakes a saved iPhone hotspot) and
  returns its exit status, a refusal it merely prints reported as 1, and 124
  when the same 30 s watchdog killed it;
  `wifi_prompt` raises YBar's own key panel for a locked network's password —
  the panel keeps the password, pipes it to `networksetup`'s stdin, owns the
  retries (a wrong password keeps it open; its join runs under a 30 s
  watchdog whose kill is exit 124, shown as a timeout rather than blamed on
  the password) and calls back once when it closes, with `""` and 0 (joined)
  or 2 (cancelled) — the password never reaches Lua or a log.
  `wifi_disconnect` drops the association and leaves Wi-Fi on. The reference
  consumer is
  [`examples/ysuite-liquid/items/widgets/wifi.lua`](../examples/ysuite-liquid/items/widgets/wifi.lua).
  Saved-hotspot rows come from a read of CoreWLAN's private
  `_isPersonalHotspot` flag through the public Objective-C runtime — the
  engine's one undocumented-ABI read, presence- and type-checked; when either
  check fails the list simply has no hotspot rows
- Running apps, permission-free: `ybar --query apps` → `[{name, bundle_id, pid,
  active, hidden}]` (also `ybar.query_table("apps")` as a Lua table; `apps` is a
  reserved query target like `bar`/`displays`, so it shadows an item of that
  name when you query BY NAME — an item handle's `handle:query()` always
  describes its own item, and `ybar.query_table(name, true)` asks for the item
  explicitly) and `ybar --app <pid|bundle-id>
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
- `ybar start|stop|restart|status` drive that bundle from the command line:
  `start` launches YBar.app (or kickstarts the login job when one owns the
  bar), `stop` waits for the process to go, `restart` replaces even a bar that
  has stopped answering, `status` reports bar, config and autostart state;
  exit codes 0 / 1 failed / 2 usage
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
