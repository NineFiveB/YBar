# YBar Architecture

This document is the synthesis of a deep dissection of sketchybar v2.24.0's source, a survey of Waybar's config/module model, and research into Metal 2D rendering and modern macOS windowing (macOS 15 Sequoia / 26 Tahoe). It is the authoritative design for YBar v1 (historical: the "v1.5" items below have since shipped). Research reports live in the project history; sketchybar `file:line` references refer to its `src/` tree.

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
| Private API required for core operation | **100% public API in v1**; private SkyLight behind protocols, opt-in | Tahoe churn firewall (macOS 26 already forced sketchybar into dlsym shims) |
| Data via plugin shell scripts polling | Built-in native providers publish typed values + events | Kills shell-out-per-second; scripts remain fully supported |

## 2. Process model & lifecycle

- `main.swift`: if argv has domain args → `CLIClient.send(argv)` → print reply, exit (`[!]`-prefixed reply → stderr, exit 1 — sketchybar convention). Else daemon.
- Daemon boot: acquire instance lock (bind the socket; `EADDRINUSE` + live ping = already running), `NSApplication` with `.accessory` policy, start `DisplayManager` → `BarManager` (bar per display), start `EventBus` + always-on providers, start `IPCServer`, exec config, `NSApp.run()`.
- **All state mutation is main-thread serialized** (sketchybar's `dispatch_sync`-to-main model, kept deliberately): IPC commands, provider callbacks, and mouse events all hop to `@MainActor`. No locks in the model layer.
- Config discovery (sketchybar-compatible): `-c <path>`, else `$XDG_CONFIG_HOME/ybar/ybarrc`, else `~/.config/ybar/ybarrc`, else `~/.ybarrc`. The config is an **executable script** run with `CONFIG_DIR` set and cwd = config dir; it configures everything through the CLI. `--reload` / FSEvents hotload (0.5 s latency, ~1 s rate limit) = full teardown + re-exec, no diffing.
- Instance naming: `ybar` binary name → socket `/tmp/ybar_<user>.socket`, env `BAR_NAME=ybar`. A renamed binary is an independent instance (sketchybar behavior).

## 3. Windowing

**Principle: 100% public API in v1; every private capability behind a protocol with a public fallback.**

Per screen, `AppKitBarSurface` builds:

```
NSPanel (.borderless, .nonactivatingPanel, clear, no shadow, isMovable=false)
└── NSVisualEffectView (blendingMode: .behindWindow, optional, maskImage for rounded/pill bars)
└── MetalHostView (layer-hosting NSView, CAMetalLayer on top)
```

- Levels mirror sketchybar's `topmost` triad: default `kCGBackstopMenuLevel` (−20, behind app windows — visible because windows avoid the menu-bar strip), `topmost=window` → `.floating` (3), `topmost=on` → `.statusBar` (25, covers the menu bar).
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]`; `canBecomeKey/Main = false`. This covers all-spaces stickiness and visibility over fullscreen apps publicly; sketchybar's private own-Space trick (`SLSSpaceCreate` + absolute level 0) only adds "visible during space-transition animations" — acceptable loss, recoverable later via `SkyLightBarSurface`.
- Frame math: top/bottom position, margin, y_offset, corner radius; menu-bar strip height from `NSScreen.frame.maxY − visibleFrame.maxY`; notch via `safeAreaInsets.top` + `auxiliaryTopLeftArea/auxiliaryTopRightArea` (better than sketchybar's manual `notch_width` — but keep `notch_width` as an override knob). No public way to *reserve* screen space (no layer-shell equivalent); document the yabai `external_bar` / AeroSpace `gaps.outer.top` pairing exactly as sketchybar does.
- Blur: `NSVisualEffectView` material as default (public, matches system, light/dark aware). `SLSSetWindowBackgroundBlurRadius` later, opt-in (`blur.style=raw`), dlsym-resolved, never linked.
- Mouse: `NSTrackingArea` on the host view; own hit-testing against item frames; `ignoresMouseEvents` toggled dynamically so decorative regions are click-through (public overlay-app pattern).
- Displays: enumerate `NSScreen.screens`, key surfaces by display UUID (`CGDisplayCreateUUIDFromDisplayID` — IDs churn); rebuild on `didChangeScreenParametersNotification` + `CGDisplayRegisterReconfigurationCallback` (debounced full reset, like sketchybar's sledgehammer — correct call). Per-screen `backingScaleFactor` → layer `contentsScale`/`drawableSize`; handle `viewDidChangeBackingProperties`.
- Spaces intel (space ids, fullscreen detection, per-space windows) is private-only; v1 ships `PublicSpaceObserver` (`NSWorkspace.activeSpaceDidChangeNotification`, no ids) + first-class **AeroSpace/yabai workspace adapters**; `SLSSpaceObserver` is a v2 opt-in module.

## 4. Rendering

Retained scene graph → flat display list → ≤4 instanced draws. Design follows Zed's GPUI and Ghostty, adapted down to bar scale.

- **Layer**: `CAMetalLayer` in a layer-hosting NSView (not MTKView). `bgra8Unorm_srgb` + sRGB colorspace, `framebufferOnly=true`, non-opaque, `displaySyncEnabled=true`, `maximumDrawableCount=2`(–3). `presentsWithTransaction` flipped on **only** for frames where AppKit geometry changes in the same transaction (bar resize/show/hide): encode → commit → `waitUntilScheduled` → present; off in steady state.
- **Redraw policy**: no loop, ever. Model changes set a dirty flag → coalesced single frame render. `NSView.displayLink` (CADisplayLink, macOS 14+, auto per-display refresh) runs **only while animations are active**; `preferredFrameRateRange` capped at 60 by default (config: up to 120). Acceptance: `powermetrics -s gpu_power` shows ~0% GPU residency when idle; Metal System Trace shows zero command buffers between updates.
- **Shapes**: instanced unit quads, vertex-pulled; fragment shader evaluates analytic SDF: per-corner-radius rounded rect, border via `abs(d+w/2)−w/2`, squircle via superellipse exponent (`cornerExponent`: 2 = circular, ≈4.5 = continuous), Evan-Wallace closed-form gaussian shadow (no blur passes), 2-stop gradients interpolated in linear space. Coverage AA via `fwidth`/`smoothstep`; `rasterSampleCount = 1`, no MSAA. Pixel-snap item origins and 1px borders.
- **Text**: CoreText shaping (`CTLineCreateWithAttributedString` → runs; free font fallback incl. CJK) → glyph raster atlas: `r8Unorm` page for monochrome masks (tinted in-shader), `bgra8Unorm` page for color (emoji, multicolor SF Symbols). Shelf bin-packing; per-scale atlases; 3–4 subpixel x-bins at 1x, whole-pixel at 2x; baseline always pixel-snapped. SF Symbols rasterized from `NSImage(systemSymbolName:)` with symbol configuration into the mask atlas → animatable tint. Shaped-line cache keyed by (string, font, size). Optional stem-darkening knob (kitty/Ghostty precedent). Fonts parsed as `"Family:Style:Size"` (sketchybar compat) via `CTFontDescriptor`.
- **Batching**: fixed paint order (bar bg → item shadows → item bg → content), sort display list by (pipeline, texture): quad pipeline (untextured SDF), glyph pipeline (mask atlas), image pipeline (color atlas + app icons/images). Triple-buffered `.storageModeShared` instance ring buffers behind a `DispatchSemaphore(3)`; `setVertexBytes` for uniforms. Full re-encode every dirty frame — damage tracking gates *whether* a frame renders, never *what*.
- **GPU structs** (16-byte aligned): `QuadInstance` {origin, size, radii(4), fill, fill2, gradientDir, borderColor, borderWidth, cornerExponent, shadowBlur, kind}, `GlyphInstance` {origin, size, uvOrigin, uvSize, color, flags}.
- Popups (later milestone) are separate small windows, same renderer, own scene.

## 5. Item model & layout

sketchybar's composition tree, formalized as value-typed Swift:

```
Item
├── style: BackgroundStyle (color, gradient, border, cornerRadius/exponent, shadow, image, height, insets…)
├── icon:  TextPart  (string, font, color, highlight, padding, y_offset, own BackgroundStyle, shadow…)
├── label: TextPart
├── content: .none | .graph(GraphState) | .slider(SliderState) | .image  (the "sandwich", later)
├── position: left|right|center|centerLeft(q)|centerRight(e)|popup(host)
├── scripting: script, clickScript, updateFreq, updateMask, updates(on|off|when_shown)
└── association: displays bitmask, spaces bitmask, drawing, width(fixed|dynamic), y_offset…
```

- **Defaults**: `--default` maintains a prototype `ItemStyle` applied at `--add` — value semantics replace sketchybar's `memcpy` + clear-pointers dance.
- **Layout** is a pure function `layout(items, barFrame, notch) → [ItemFrame]`: sketchybar's proven five-cursor algorithm (left→, ←right, centered center block needing a pre-pass length sum, and notch-anchored q/e cursors flowing away from the notch dead zone). Measure (CoreText metrics + paddings) → arrange → encode, as distinct phases. Item length = icon + content + label; paddings outside; `width=<n>` fixed override with `align` l/c/r inside.
- **Brackets** (v1.5): derived nodes — background spanning the union of member frames, drawn *behind* members (paint order, no window tricks).
- **Property namespace**: the dotted recursive path grammar is **the compatibility surface** and is kept verbatim from sketchybar: `icon.background.shadow.color.alpha`, `label.font.size`, `background.corner_radius`, every color addressable as `.hex|.alpha|.red|.green|.blue`. Implemented as a recursive descent over typed sub-parsers, exactly mirroring sketchybar's `bar_item_parse_set_message` structure. Booleans accept `on/off/true/false/yes/no/1/0/toggle`. Colors are `0xAARRGGBB`.

## 6. Animation

sketchybar's UX (message-scoped `--animate <curve> <duration>`, duration in 60ths-of-a-second, every subsequent `--set` in the message animates) is kept verbatim — and upgraded:

- `PropertyAnimator` keyed by (item, keyPath): typed interpolation (`Float`, `CGPoint`, `Insets`, `Color` — colors lerp in linear sRGB/OKLab, not per-byte ARGB like sketchybar's off-hue midpoints).
- Same-key replacement chains sequentially (sketchybar semantics: new animation queues from previous final value; re-set cancels-and-snaps).
- Curves: `linear, sin, quadratic, tanh, exp, circ` (first-letter parse, compat) **plus** working `bounce`, `overshoot` (sketchybar reserved the names but never implemented them) and `spring` (critically-damped default) as YBar extensions.
- Tick source: the per-display `NSView.displayLink`; scheduler starts it when the first animator is added, invalidates on the last removal. Width changes under animation auto-animate (`width=dynamic` idiom preserved).
- Periodic items (clock) are **timers with leeway**, not animations.

## 7. IPC & CLI

**Transport**: Unix domain socket `/tmp/ybar_<user>.socket`, mode 0600. Framing: `u32 LE length` + payload; payload = argv tokens NUL-separated with trailing double-NUL (sketchybar wire format, preserved because it makes `ybar --set foo label="hello world"` trivially correct). Response: `u32 LE length` + UTF-8 text. Client timeout ~1 s. The daemon parses payloads with the same tokenizer as sketchybar (`--`-prefixed domain tokens batch until the next `-` token), so **one invocation batches many domains**.

**v1 command set** (the researched "20% that is 80% of value"):

```
--bar <prop>=<val>…             --default <prop>=<val>… | reset
--add item <name> <pos>         --add event <name> [<distributed-notification>]
--set <name> <prop>=<val>…      --remove <name>
--subscribe <name> <event>…     --trigger <event> [KEY=VAL…]
--animate <curve> <frames>      --update
--query bar|<item>|defaults|events|displays
--reload [path]                 --hotload <on|off>
```

v1.5: `--add graph|slider|bracket`, `--push`, `--clone/--rename/--move/--reorder`, regex item targeting, `--load-font`. Deferred: `alias` (ScreenCaptureKit route, opt-in Screen Recording), `space` component (via WM adapters first), mach-helper fast path (YBar equivalent: a socket event-push subscription for SbarLua-style bindings).

**`--query` output**: JSON matching sketchybar's key names (scripts pipe it to `jq`; keep `name`, `geometry`, `icon`, `label`, `scripting`, `bounding_rects` shapes) via `Codable` with explicit keys.

## 8. Events & providers

**EventBus**: named events with a subscriber bitmask per item (u64, sketchybar-compatible cap is fine v1), routed on main. Built-in v1 events: `front_app_switched, space_change, display_change, system_woke, system_will_sleep, power_source_change, battery_change*, volume_change, wifi_change, mouse.entered, mouse.exited, mouse.clicked, mouse.scrolled` (* = YBar addition: percentage changes, not just AC/battery flips). Custom events: `--add event <name> [notification]` — optional binding to `NSDistributedNotificationCenter` with `userInfo` JSON-serialized into `INFO` (this is how Spotify integration works; cheap, ship in v1). `--trigger` injects arbitrary env pairs.

**Script contract (verbatim sketchybar)**: `NAME`, `SENDER` (event | `routine` | `forced`), `INFO`, `BUTTON` (left|right|other), `MODIFIER` (shift|ctrl|alt|cmd), `SCROLL_DELTA`, `PERCENTAGE` (sliders), `CONFIG_DIR`, `BAR_NAME`. Scripts run `/usr/bin/env sh -c <script>` with cwd = config dir, killed after 60 s. `update_freq` in seconds, polled off a 1 Hz timer with leeway, gated by `updates=when_shown`.

**Native providers** (lazy-armed on first subscription unless noted; each with a `forced` re-query path wired to `--trigger <event>`):

| Provider | APIs (all public) | Notes |
|---|---|---|
| Workspace | `NSWorkspace` notifications (+`frontmostApplication`, app icons) | always on; front app, sleep/wake, space-change (no ids) |
| Power | `IOPSNotificationCreateRunLoopSource`, `IOPSGetPowerSourceDescription` | native percentage/charging/time — beyond sketchybar |
| Audio | CoreAudio `AudioObjectAddPropertyListenerBlock` ×5 | default-device re-arm; keep channel-1 fallback (AirPods) |
| Network | `NWPathMonitor` / `SCDynamicStore`; SSID via CoreWLAN **only after** CoreLocation auth | degrade to "connected" without location; no `ipconfig` hacks |
| SystemStats | `host_processor_info`, `host_statistics64` | built-in cpu/mem — kills the #1 external-helper use case |
| Clock | `DispatchSourceTimer` with leeway | fires on the minute/second per format |
| Media | **out-of-process only** | MediaRemote is entitlement-dead since 15.3; ship distributed-notification listeners (Music/Spotify) v1, platform-binary adapter helper later |
| Workspaces (WM) | AeroSpace/yabai CLI+socket adapters behind `WorkspaceProvider` protocol | native SLS spaces = v2 opt-in |

## 9. Config layers (progressive disclosure)

1. **Tier 3 first (v1)**: the live CLI object model above; `ybarrc` is an executable script. This is the kernel — everything else is sugar over it.
2. **Tier 2 (v1)**: script plugins via events/`update_freq` (sketchybar model) — comes free with Tier 3.
3. **YbarLua (v1.5)**: embedded Lua (SbarLua-style) speaking the socket in-process with async exec — first-class, not a bolt-on; the user's existing SbarLua-style config should port mechanically.
4. **Tier 1 declarative (v2)**: Waybar-style JSONC (`modules-left/center/right`, `format` templates, `interval`, `on-click`, `return-type: json` custom modules) + CSS-subset styling, compiled onto the Tier 3 API. State classes (`.warning`, `.charging`) map to property sets.

## 10. Package layout

```
Package.swift                     — swift-tools 6.0, macOS 14+, exec `ybar` + lib `YBarKit` + tests
Sources/ybar/main.swift           — argv → client | daemon
Sources/YBarKit/
  App/        Daemon, CLIClient, InstanceLock
  Bar/        BarManager, BarSurface (protocol + AppKit impl), BarSettings, DisplayManager, MouseRouter
  Items/      Item, ItemStore, Style types, Layout, PropertySetter (dotted paths), Serialize (query JSON)
  Render/     MetalHostView, Renderer, SceneBuilder, GlyphAtlas, FontCache, Instances, Shaders/YBar.metal
  Animation/  AnimationScheduler, PropertyAnimation, Curves
  IPC/        WireFormat, SocketServer, SocketClient, CommandParser, CommandHandler
  Events/     EventBus, Event, ScriptRunner
  Providers/  WorkspaceProvider, PowerProvider, AudioProvider, NetworkProvider, SystemStatsProvider, ClockProvider
  Config/     ConfigLocator, Hotload
Tests/YBarKitTests/               — layout, wire format, property parsing, curves, command grammar
```

Concurrency: Swift 6 language mode; model layer is `@MainActor`; providers hop callbacks to main; renderer encodes on main (bar frames are microseconds), presents async.

## 11. Milestones

- **M0 — skeleton**: builds; bar window per display at correct frame/level; Metal clear + SDF bar background; `--bar color=…` over IPC works. Acceptance: bar visible on all spaces, idle GPU ≈ 0.
- **M1 — items & text**: `--add item`, `--set icon=/label=` with fonts/colors/padding/backgrounds, five-cursor layout, `--query`. Glyph atlas with fallback + SF Symbols + emoji.
- **M2 — events & scripts**: EventBus, script runner + env contract, `--subscribe/--trigger/--add event` + distributed notifications, clock/power/audio/workspace providers, `update_freq`, config exec + hotload, mouse events + click scripts.
- **M3 — animation**: `--animate`, curves incl. spring, animated layout (items slide on add/remove/width change).
- **M4 — components**: graph, slider, brackets, popups; SystemStats + Network providers; AeroSpace adapter.
- **M5 — polish**: YbarLua, alias via ScreenCaptureKit, JSONC tier, `SkyLightBarSurface` opt-in, signed/notarized .app + brew cask.

## 12. Risk register

- **macOS 26 Liquid Glass / API churn**: v1 public-only; treat every future SLS call as per-version-gated behind protocols; Tahoe rounds screen corners and changed menu-bar metrics — all metrics config-driven.
- **MediaRemote is dead** (entitlement-locked since 15.3): never in-process; distributed notifications first, platform-binary adapter as best-effort helper.
- **Wi-Fi SSID requires Location** and a real bundle for TCC attribution: bare-executable v1 shows connectivity only; SSID lights up when we ship the .app bundle (M5).
- **No exclusive screen space** exists publicly: document WM-gap pairing; default level −20 keeps the bar unobtrusive without reservation.
- **TCC grant loss on rebuilds** (sketchybar's ad-hoc-signing pain): ship Developer-ID-signed with stable bundle ID at M5; until then core needs zero TCC.
