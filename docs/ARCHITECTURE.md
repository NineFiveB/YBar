# YBar Architecture

This document is the synthesis of a deep dissection of sketchybar v2.24.0's source, a survey of Waybar's config/module model, and research into Metal 2D rendering and modern macOS windowing (macOS 15 Sequoia / 26 Tahoe). It is the original v1 design, kept as the record of why things are the way they are (historical: the "v1.5" items below have since shipped; where the tree has moved past the plan — §2, §3, §4, §7, §10, §11, §12 — a note beside the text says what is there today). Research reports live in the project history; sketchybar `file:line` references refer to its `src/` tree.

## 1. Overview

YBar is a single Swift binary (`ybar`) that is both daemon and CLI client — sketchybar's proven model. The daemon owns one GPU-rendered bar window per display, a live item tree mutable at runtime over IPC, an event bus fed by native providers, and script plugins. Rendering is a retained scene graph encoded into a few instanced Metal draws; the GPU does zero work while the bar is static.

```
ybar (no args)          → daemon: windows, renderer, event bus, IPC server, exec ybarrc
ybar --add/--set/...    → thin client: serialize argv → unix socket → print response
```

Key departures from sketchybar, each justified by research:

| sketchybar | YBar | Why |
|---|---|---|
| One SLS window **per item** per display, private SkyLight everywhere | **One NSPanel + CAMetalLayer per display**; items are scene-graph nodes | The per-item-window design exists only to get WindowServer-side tracking + cheap CPU partial redraw. Metal redraws the whole bar in microseconds; ~80% of the private API surface disappears |
| CPU CoreGraphics raster → CALayer.contents | Instanced SDF quads + glyph atlas on GPU | Full-speed animation, gradients, real gaussian shadows, squircles, shader modules |
| Carbon event loop, no NSApplication | Ordinary AppKit app (`.accessory` activation policy) | NSTrackingArea/NSEvent replace Carbon + private CGEvent field hacks, zero permissions |
| mach bootstrap port (`bootstrap_register`, deprecated) | Unix domain socket, length-framed | Simpler, debuggable, any-language clients; same NUL-separated argv payload |
| Private API required for core operation | **100% public API** — the v1 plan kept a slot for opt-in SkyLight modules behind protocols; that slot was closed, nothing in the tree links or dlsyms a private symbol (see VISION.md) | Tahoe churn firewall (macOS 26 already forced sketchybar into dlsym shims) |
| Data via plugin shell scripts polling | Built-in native providers publish typed values + events | Kills shell-out-per-second; scripts remain fully supported |

## 2. Process model & lifecycle

- `main.swift`: `ybar theme …` and `ybar autostart …` are local verbs (`LocalVerbs.run`; they never touch the socket and work with no daemon); `-h/--help` and `-v/--version` print locally; otherwise if argv has domain args → `CLIClient.runIfClient` → `SocketClient.send(argv)` → print reply, exit (`[!]`-prefixed reply → stderr, exit 1 — sketchybar convention). Else (no args, or `-c <path>`) daemon.
- Daemon boot: `NSApplication` with `.accessory` policy, then in `applicationDidFinishLaunching` the instance lock **first** — bind the socket (a node that answers `--ping` means already running: exit non-zero; a dead node is recycled; a node this process did not bind is never unlinked) — then `BarManager.begin()` (bar per display), scheduler / event-bus / provider / mouse wiring, the 1 Hz routine timer, and the config run. A request that lands on the socket before that point waits on the accept thread.
- **All state mutation is main-thread serialized** (sketchybar's `dispatch_sync`-to-main model, kept deliberately): IPC commands, provider callbacks, and mouse events all hop to `@MainActor`. No locks in the model layer.
- Config discovery (sketchybar-compatible, `ConfigLocator`): `-c <path>`; else the theme selected with `ybar theme use` (`~/.config/ybar/current-theme`, honoured for the default `ybar` instance only; a stale name falls through); else per directory `ybarrc.lua`, `ybarrc`, `ybarrc.jsonc`, `ybar.jsonc` under `$XDG_CONFIG_HOME/ybar/` then `~/.config/ybar/`; else `~/.ybarrc.lua`, `~/.ybarrc`. Dispatch is by extension: `.lua` runs in the embedded YbarLua runtime, `.json`/`.jsonc` is translated through the command layer, anything else is an **executable script** run with `CONFIG_DIR` set and cwd = config dir, configuring everything through the CLI. `--reload [path]` (a path re-points the daemon — how `ybar theme use` switches a running bar) and hotload (`--hotload on`: a `DispatchSource` vnode watch on the config file and its directory, not FSEvents; 0.5 s trailing-edge debounce; events within 1 s of a reload are suppressed so the config's own writes cannot loop) = full teardown + re-exec, no diffing.
- Instance naming: `ybar` binary name → socket `/tmp/ybar_<user>.socket`, env `BAR_NAME=ybar`. A renamed binary is an independent instance (sketchybar behavior).

## 3. Windowing

**Principle: 100% public API.** (Historical: v1 planned a protocol slot for private capabilities with public fallbacks; no such module was ever built and the rule is now absolute.)

Per screen, `AppKitBarSurface` builds:

```
NSPanel (.borderless, .nonactivatingPanel, clear, no shadow, isMovable=false)
└── NSVisualEffectView (blendingMode: .behindWindow, optional, maskImage for rounded/pill bars)
└── MetalHostView (layer-hosting NSView, CAMetalLayer on top)
```

- Levels mirror sketchybar's `topmost` triad: default `kCGBackstopMenuLevel` (−20, behind app windows — visible because windows avoid the menu-bar strip), `topmost=window` → `.floating` (3), `topmost=on` → `.statusBar` (25, covers the menu bar).
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`; `canBecomeKey/Main = false`. This covers all-spaces stickiness and visibility over fullscreen apps publicly; sketchybar's private own-Space trick (`SLSSpaceCreate` + absolute level 0) only adds "visible during space-transition animations" — an accepted loss (the planned `SkyLightBarSurface` was never built). Fullscreen Spaces: by default the panels are carried onto them at their configured level (covered by the fullscreen window unless `topmost=on` already clears it); `fullscreen_show=on` raises the bar to status level over it; `fullscreen_hide=on` (opt-in) drops `.fullScreenAuxiliary` from the bar, popup and tooltip panels so the WindowServer keeps them off fullscreen Spaces — no polling, no private API — and wins over `fullscreen_show`. `--query bar` reports both flags.
- Frame math: top/bottom position, margin, y_offset, corner radius; menu-bar strip height from `NSScreen.frame.maxY − visibleFrame.maxY`; notch via `safeAreaInsets.top` + `auxiliaryTopLeftArea/auxiliaryTopRightArea` (better than sketchybar's manual `notch_width` — but keep `notch_width` as an override knob). No public way to *reserve* screen space (no layer-shell equivalent); document the yabai `external_bar` / AeroSpace `gaps.outer.top` pairing exactly as sketchybar does.
- Blur: `NSVisualEffectView` material as default (public, matches system, light/dark aware); on macOS 26 the bar, pills and popups can sit on `NSGlassEffectView` (`glass=on`). (Historical: a dlsym-resolved `SLSSetWindowBackgroundBlurRadius` opt-in was planned and dropped with the private-API slot.)
- Mouse: `NSTrackingArea` on the host view; own hit-testing against item frames; `ignoresMouseEvents` toggled dynamically so decorative regions are click-through (public overlay-app pattern).
- Displays: enumerate `NSScreen.screens`, key surfaces by display UUID (`CGDisplayCreateUUIDFromDisplayID` — IDs churn); rebuild on `didChangeScreenParametersNotification` + `CGDisplayRegisterReconfigurationCallback` (debounced full reset, like sketchybar's sledgehammer — correct call). Per-screen `backingScaleFactor` → layer `contentsScale`/`drawableSize`; handle `viewDidChangeBackingProperties`.
- Spaces intel (space ids, fullscreen detection, per-space windows) is private-only; v1 ships `PublicSpaceObserver` (`NSWorkspace.activeSpaceDidChangeNotification`, no ids) + first-class **AeroSpace/yabai workspace adapters** (theme-side, in the shipped configs); the planned `SLSSpaceObserver` opt-in was dropped with the private-API slot.

## 4. Rendering

Retained scene graph → flat display list → ≤4 instanced draws. Design follows Zed's GPUI and Ghostty, adapted down to bar scale.

- **Layer**: `CAMetalLayer` in a layer-hosting NSView (not MTKView). `bgra8Unorm_srgb` + sRGB colorspace, `framebufferOnly=true`, non-opaque, `maximumDrawableCount=3`. (Historical: the planned `presentsWithTransaction` toggle for geometry-changing frames was never needed — every frame is `present(drawable)` + `commit()` behind the semaphore below, and a size or scale change schedules a corrective frame.)
- **Redraw policy**: no loop, ever. Model changes set a dirty flag → coalesced single frame render. `NSView.displayLink` (CADisplayLink, macOS 14+, the display's own refresh rate) runs **only while animations are active or a marquee demands continuous frames**, and is invalidated on the last removal. There is no frame-rate cap: `--animate` durations are frames-at-60 Hz converted to seconds, so a ProMotion display draws more frames for the same wall-clock duration, not a faster animation. Acceptance: `powermetrics -s gpu_power` shows ~0% GPU residency when idle; Metal System Trace shows zero command buffers between updates.
- **Shapes**: instanced unit quads, vertex-pulled; fragment shader evaluates analytic SDF: per-corner-radius rounded rect, border via `abs(d+w/2)−w/2`, squircle via superellipse exponent (`cornerExponent`: 2 = circular, ≈4.5 = continuous), shadows as a second quad behind the plate — a hard offset copy by default, and with `shadow.blur > 0` the quad is grown by the blur on every side, carries the true half size in `fill2.xy` and the blur radius in `gradientDir.x`, and flag bit 4 (`flagShadow`) turns the AA edge into a squared-smoothstep falloff of the SDF (no blur passes; a light colour at distance 0 is a glow) — 2-stop gradients interpolated in linear space. Coverage AA via `fwidth`/`smoothstep`; `rasterSampleCount = 1`, no MSAA. Pixel-snap item origins and 1px borders.
- **Text**: CoreText shaping (`CTLineCreateWithAttributedString` → runs; free font fallback incl. CJK) → glyph raster atlas: `r8Unorm` page for monochrome masks (tinted in-shader), `bgra8Unorm` page for color (emoji, multicolor SF Symbols). Shelf bin-packing; cache keys bucket sizes to quarter points so an animated font size does not mint a glyph per frame (the packer never reclaims); baseline always pixel-snapped; `icon.shadow`/`label.shadow` are a second copy of the glyph run at the offset, drawn before the ink. SF Symbols rasterized from `NSImage(systemSymbolName:)` with symbol configuration into the mask atlas → animatable tint. Shaped-line cache keyed by (string, font, size). (Historical: the optional stem-darkening knob was never added.) Fonts parsed as `"Family:Style:Size"` (sketchybar compat) via `CTFontDescriptor`.
- **Batching**: fixed paint order (bar bg → bracket backgrounds → per item: shadow, background, the icon/label plates — `icon.background.*` / `label.background.*` render at ink width plus their own paddings without widening layout — then content), three pipelines: quad (untextured SDF), shape (raw triangles: graph fills and strokes), glyph (both atlas pages — mask and colour — which is also where images and app icons are drawn). Triple-buffered `.storageModeShared` instance ring buffers behind a `DispatchSemaphore(3)`; `setVertexBytes` for uniforms. Full re-encode every dirty frame — damage tracking gates *whether* a frame renders, never *what*.
- **GPU structs** (16-byte aligned): `QuadInstance` {origin, size, radii(4), fill, fill2, gradientDir, borderWidth, cornerExponent, borderColor, flags} — 112 bytes; `GlyphInstance` {origin, size, uvOrigin, uvSize, color, flags} — 64 bytes; `ShapeVertex` 32 bytes; `HoleInstance` (`background.clip` cutouts) 48 bytes; `Uniforms` 16 bytes. Flag bits, strides and every field offset are pinned by `InstancesTests` and re-checked at renderer init (`InstanceLayout.mismatch()` — a drift is a logged startup failure, not a trap). The Windows port shares the layout byte-for-byte except `Hole`, which is 32 bytes there.
- Popups and tooltips are separate panels (`PopupSurface`), same renderer, own scene. `popup.fade_in` / `popup.fade_out` (frames at 60 Hz, 0 = hard cut) ramp the panel's alpha on the window server on open and close: a closing panel ignores the mouse, a reopen mid-fade restarts the ramp from 0, and tooltips keep the hard cut.

## 5. Item model & layout

sketchybar's composition tree, formalized as value-typed Swift:

```
Item
├── style: BackgroundStyle (color, gradient, border, cornerRadius/exponent, shadow, image, height, insets…)
├── icon:  TextPart  (string, font, color, highlight, padding, y_offset, own BackgroundStyle, shadow…)
├── label: TextPart
├── content: graph | slider | image | gauge | alias state  (the "sandwich" between icon and label)
├── position: left|right|center|centerLeft(q)|centerRight(e)|popup(host)
├── scripting: script, clickScript, updateFreq, updateMask, updates(on|off|when_shown)
└── association: displays bitmask, spaces bitmask, drawing, width(fixed|dynamic), y_offset…
```

- **Defaults**: `--default` maintains a prototype `ItemStyle` applied at `--add` — value semantics replace sketchybar's `memcpy` + clear-pointers dance.
- **Layout** is a pure function `layout(items, barFrame, notch) → [ItemFrame]`: sketchybar's proven five-cursor algorithm (left→, ←right, centered center block needing a pre-pass length sum, and notch-anchored q/e cursors flowing away from the notch dead zone). Measure (CoreText metrics + paddings) → arrange → encode, as distinct phases. Item length = icon + content + label; paddings outside; `width=<n>` fixed override with `align` l/c/r inside.
- **Brackets** (v1.5): derived nodes — background spanning the union of member frames, drawn *behind* members (paint order, no window tricks).
- **Property namespace**: the dotted recursive path grammar is **the compatibility surface** and is kept verbatim from sketchybar: `icon.background.shadow.color.alpha`, `label.font.size`, `background.corner_radius`, every color addressable as `.hex|.alpha|.red|.green|.blue`. Implemented as a recursive descent over typed sub-parsers, exactly mirroring sketchybar's `bar_item_parse_set_message` structure. Booleans accept `on/off/true/false/yes/no/1/0/toggle` — `toggle` on every item leaf; at bar level only `hidden` and `idle_inhibit` toggle (the Windows spec's rule). Colors are `0xAARRGGBB`.

## 6. Animation

sketchybar's UX (message-scoped `--animate <curve> <duration>`, duration in 60ths-of-a-second, every subsequent `--set` in the message animates) is kept verbatim — and upgraded:

- `PropertyAnimator` keyed by (item, keyPath): typed interpolation (`Float`, `CGPoint`, `Insets`, `Color` — colors lerp in linear sRGB/OKLab, not per-byte ARGB like sketchybar's off-hue midpoints).
- Same-key replacement chains sequentially (sketchybar semantics: new animation queues from previous final value; re-set cancels-and-snaps).
- Curves: `linear, sin, quadratic, tanh, exp, circ` (first-letter parse, compat) **plus** working `bounce`, `overshoot` (sketchybar reserved the names but never implemented them) and `spring` (critically-damped default) as YBar extensions.
- Tick source: the per-display `NSView.displayLink`; scheduler starts it when the first animator is added, invalidates on the last removal. Width changes under animation auto-animate (`width=dynamic` idiom preserved).
- Periodic items (clock) are **timers with leeway**, not animations.

## 7. IPC & CLI

**Transport**: Unix domain socket `/tmp/ybar_<user>.socket`, mode 0600. Framing: `u32 LE length` + payload; payload = argv tokens NUL-separated with trailing double-NUL (sketchybar wire format, preserved because it makes `ybar --set foo label="hello world"` trivially correct). Response: `u32 LE length` + UTF-8 text. Client timeout 5 s. The daemon parses payloads with the same tokenizer as sketchybar (`--`-prefixed domain tokens batch until the next `-` token), so **one invocation batches many domains**.

**Command set** (historical: v1 shipped the researched "20% that is 80% of value" first; everything below is live):

```
--bar <prop>=<val>…                   --default <prop>=<val>… | reset
--add item <name> <pos>               --add event <name> [<distributed-notification>]
--add graph|slider <name> <pos> <w>   --add bracket <name> <member>…
--add alias "Owner[,Window]" <pos>    --set <name> <prop>=<val>…
--remove <name>                       --subscribe <name> <event>…
--trigger <event> [KEY=VAL…]          --animate <curve> <frames>
--update                              --push <graph> <value>…
--query bar|defaults|events|displays|apps|<item>
--move <name> before|after <anchor>   --reorder <name>…
--rename <old> <new>                  --clone <new> <source> [before|after]
--reload [path]                       --hotload on|off
--volume <0-100|+N|-N>                --app <pid|bundle-id> activate|hide|quit|kill
--ping                                --exit
```

`<name>` in `--set` and `--remove` may be a `/regex/`. Of the v1.5 list — `--add graph|slider|bracket`, `--push`, `--clone/--rename/--move/--reorder`, regex targeting — everything shipped except `--load-font`, which was never needed (fonts resolve by name through CoreText). Of the deferred items, `alias` shipped on ScreenCaptureKit (opt-in Screen Recording; a click on an alias with no script and no Lua handler is forwarded to the captured item, which needs Accessibility), the `space` component is the AeroSpace/yabai adapters in the shipped themes, and the mach-helper fast path became the embedded Lua runtime (§9) — configs run in-process, no socket round trip.

Two verbs are YBar extensions mirrored from the Windows port. `--volume <0-100|+N|-N>` writes the default output device through CoreAudio in-process (`0` mutes and keeps the level so unmuting restores it; `+N`/`-N` step from the level the device is holding, mute included — a `+N` on a muted Mac resumes from the kept level and unmutes there, a `-N` leaves it muted; the port's optional per-app second token is refused by name — macOS has no per-app volume API); the Lua form is `ybar.volume(pct)`, a number being absolute — saturated into 0-100 before it becomes a token, so arithmetic that undershoots mutes instead of stepping — and a signed string (`"+4"`) relative, returning nil or a `[!]` string. `--app <pid|bundle-id> activate|hide|quit|kill` acts through `NSRunningApplication` — the action is validated before the target is resolved, and a bundle id reaches every process it matches. Window titles and frames are deliberately out of scope: they need Screen Recording.

**`--query` output**: JSON matching sketchybar's key names (scripts pipe it to `jq`; keep `name`, `geometry`, `icon`, `label`, `scripting`, `bounding_rects` shapes) via `Serialize` — pretty-printed, sorted keys, colours as `0x%08x`. `bar`, `defaults`, `events`, `displays` and `apps` are reserved targets that shadow an item of the same name (sketchybar-style; one rule, applied before item lookup for the CLI and for Lua's `ybar.query_table`, which returns every reserved target as a table). Shadowing is for queries BY NAME only: an item handle's `handle:query()` describes the handle's own item, since a config that names an item `apps` must still be able to read it back (`ybar.query_table(name, true)` is the explicit form). `apps` is the permission-free app level: every Dock-visible app in launch order as `[{name, bundle_id, pid, active, hidden}]` — no window titles, so no Screen Recording.

Boolean shape — pinned on both platforms, do not "fix" either side: sketchybar's `drawing` flags are the strings `"on"`/`"off"` (`geometry.drawing`, `icon.drawing`, `label.drawing`, `image.drawing`, `popup.drawing`, every `background.drawing` and `shadow.drawing`, plus `background.glass`, `slider.interactive` and `image.desaturate`); everything else is a JSON boolean — at bar level `hidden`, `sticky`, `fullscreen_show`, `fullscreen_hide`, `idle_inhibit`; per item `icon.highlight`/`label.highlight`, `popup.horizontal`, `popup.auto_close`; `main` in `displays`, `active`/`hidden` in `apps`. Lua's `ybar.query_table` sees real booleans for both kinds. Scripts in the wild already parse `true`, and the Windows serializer mirrors the mix byte-for-byte, so the wire shape is frozen.

## 8. Events & providers

**EventBus**: named events with a subscriber bitmask per item (u64, sketchybar-compatible cap is fine v1), routed on main. Built-in v1 events: `front_app_switched, space_change, display_change, system_woke, system_will_sleep, power_source_change, battery_change*, volume_change, wifi_change, mouse.entered, mouse.exited, mouse.clicked, mouse.scrolled` (* = YBar addition: percentage changes, not just AC/battery flips). Custom events: `--add event <name> [notification]` — optional binding to `NSDistributedNotificationCenter` with `userInfo` JSON-serialized into `INFO` (this is how Spotify integration works; cheap, ship in v1). `--trigger` injects arbitrary env pairs.

**Script contract (verbatim sketchybar)**: `NAME`, `SENDER` (event | `routine` | `forced`), `INFO`, `BUTTON` (left|right|other), `MODIFIER` (shift|ctrl|alt|cmd), `SCROLL_DELTA`, `PERCENTAGE` (sliders), `CONFIG_DIR`, `BAR_NAME`. Scripts run `/usr/bin/env sh -c <script>` with cwd = config dir, killed after 60 s (SIGTERM to the child's process group, SIGKILL 2 s later — a `foo &` helper dies with its script unless it `setsid()`s; macOS ships no setsid(1) and nohup keeps the group). `update_freq` in seconds, polled off a 1 Hz timer with leeway, gated by `updates=when_shown`.

**Native providers** (lazy-armed on first subscription unless noted; each with a `forced` re-query path wired to `--trigger <event>`):

| Provider | APIs (all public) | Notes |
|---|---|---|
| Workspace | `NSWorkspace` notifications (+`frontmostApplication`, app icons) | always on; front app, sleep/wake, space-change (no ids) |
| Power | `IOPSNotificationCreateRunLoopSource`, `IOPSGetPowerSourceDescription` | always on; native percentage/charging/time — beyond sketchybar |
| Audio | CoreAudio `AudioObjectAddPropertyListenerBlock` ×5 | default-device re-arm; keep channel-1 fallback (AirPods) |
| Network | `NWPathMonitor` / `SCDynamicStore`; SSID via CoreWLAN **only after** CoreLocation auth | degrade to "connected" without location; no `ipconfig` hacks |
| SystemStats | `host_processor_info`, `host_statistics64` | built-in cpu/mem — kills the #1 external-helper use case |
| Clock | (historical — no provider was built) | periodic items are `update_freq` off the 1 Hz routine timer; the Lua themes tick their clocks themselves |
| Media | **out-of-process only** | MediaRemote is entitlement-dead since 15.3; distributed-notification listeners (Music/Spotify), armed on the first `media_change` subscription — the seed of already-running players goes through `osascript`, which is what raises the Automation prompt |
| Alias | ScreenCaptureKit, 1 Hz capture timer | `--add alias`; Screen Recording on first capture |
| Workspaces (WM) | AeroSpace/yabai CLI+socket adapters behind `WorkspaceProvider` protocol | native SLS spaces = v2 opt-in |

## 9. Config layers (progressive disclosure)

1. **Tier 3 first (v1)**: the live CLI object model above; `ybarrc` is an executable script. This is the kernel — everything else is sugar over it.
2. **Tier 2 (v1)**: script plugins via events/`update_freq` (sketchybar model) — comes free with Tier 3.
3. **YbarLua (v1.5)**: embedded Lua (SbarLua-style) speaking the socket in-process with async exec — first-class, not a bolt-on; the user's existing SbarLua-style config should port mechanically.
4. **Tier 1 declarative (v2)**: Waybar-style JSONC (`modules-left/center/right`, `format` templates, `interval`, `on-click`, `return-type: json` custom modules) + CSS-subset styling, compiled onto the Tier 3 API. State classes (`.warning`, `.charging`) map to property sets. (What shipped is `ybar.jsonc`: the same items and dotted keys declared as JSON, translated onto the command layer — not the Waybar module vocabulary.)

## 10. Package layout

```
Package.swift                     — swift-tools 6.0, macOS 14+; exec `ybar`, lib `YBarKit`, vendored `CLua`, tests
Sources/ybar/main.swift           — argv → local verb | client | daemon
Sources/CLua/                     — Lua 5.4.8, vendored verbatim (MIT)
Sources/YBarKit/
  App/        Daemon (boot, wiring, config run, reload), LocalVerbs (`ybar theme`, `ybar autostart`), JSONCConfig
  Bar/        BarManager (surfaces, hit-testing, popups), BarSurface (NSPanel + Metal host + glass), PopupSurface,
              BarSettings, BarPropertySetter (`--bar` keys), DisplayManager
  Items/      Item + ItemStore, Style (colors, backgrounds, text parts, shadows, fonts), Components (graph, slider,
              image, gauge, alias, popup state), Layout (five cursors), PropertySetter (dotted paths), Serialize (`--query`)
  Render/     MetalHostView, Renderer, SceneBuilder, GlyphAtlas, FontCache, Instances, Shaders/YBar.metal (compiled at runtime)
  Animation/  Animation (curves, typed lerps, the scheduler and its display link)
  IPC/        WireFormat, SocketServer (doubles as the instance lock), SocketClient (+ CLIClient, --help, Version),
              CommandParser, CommandHandler
  Events/     EventBus, ScriptRunner (60 s watchdog, PATH)
  Providers/  WorkspaceProvider, PowerProvider, AudioProvider, NetworkProvider, SystemStatsProvider, MediaProvider, AliasProvider
  Config/     Config (ConfigLocator + Hotload)
  Lua/        LuaRuntime (YbarLua bridge + prelude; the sbar compat shim is pure Lua shipped with the themes)
Tests/YBarKitTests/               — layout, wire format, property parsing, curves, command grammar, scene output, Lua end-to-end,
                                    socket round trips, instance ABI, provider contracts, text-metric goldens (Tests/Fixtures)
```

Concurrency: Swift 6 language mode; model layer is `@MainActor`; providers hop callbacks to main; renderer encodes on main (bar frames are microseconds), presents async.

## 11. Milestones

- **M0 — skeleton**: builds; bar window per display at correct frame/level; Metal clear + SDF bar background; `--bar color=…` over IPC works. Acceptance: bar visible on all spaces, idle GPU ≈ 0.
- **M1 — items & text**: `--add item`, `--set icon=/label=` with fonts/colors/padding/backgrounds, five-cursor layout, `--query`. Glyph atlas with fallback + SF Symbols + emoji.
- **M2 — events & scripts**: EventBus, script runner + env contract, `--subscribe/--trigger/--add event` + distributed notifications, clock/power/audio/workspace providers, `update_freq`, config exec + hotload, mouse events + click scripts.
- **M3 — animation**: `--animate`, curves incl. spring, animated layout (items slide on add/remove/width change).
- **M4 — components**: graph, slider, brackets, popups; SystemStats + Network providers; AeroSpace adapter.
- **M5 — polish**: YbarLua, alias via ScreenCaptureKit, JSONC tier, `SkyLightBarSurface` opt-in, signed/notarized .app + brew cask.

Status (historical framing): M0–M4 shipped as planned. Of M5, YbarLua, the ScreenCaptureKit alias and the JSONC tier shipped; `SkyLightBarSurface` was dropped when the public-API rule became absolute; and there is no Developer ID — the .app is built and signed locally, so distribution is a source-built Homebrew formula rather than a cask (INSTALL.md).

## 12. Risk register

- **macOS 26 Liquid Glass / API churn**: v1 public-only; treat every future SLS call as per-version-gated behind protocols; Tahoe rounds screen corners and changed menu-bar metrics — all metrics config-driven. (Outcome: no SLS call was ever added; macOS 26 glass is used through the public `NSGlassEffectView`.)
- **MediaRemote is dead** (entitlement-locked since 15.3): never in-process; distributed notifications first, platform-binary adapter as best-effort helper.
- **Wi-Fi SSID requires Location** and a real bundle for TCC attribution: bare-executable v1 shows connectivity only; SSID lights up when we ship the .app bundle (M5). (Outcome: `make app` and the formula build the bundle; `--bar wifi_ssid_prompt=on` requests the grant and the name is re-published the moment it lands.)
- **No exclusive screen space** exists publicly: document WM-gap pairing; default level −20 keeps the bar unobtrusive without reservation.
- **TCC grant loss on rebuilds** (sketchybar's ad-hoc-signing pain): ship Developer-ID-signed with stable bundle ID at M5; until then core needs zero TCC. (Outcome: there is no Developer ID; a stable self-signed "YBar Signing" certificate that `make app` picks up keeps grants across rebuilds — INSTALL.md — and the core still needs zero TCC.)
