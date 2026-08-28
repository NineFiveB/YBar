# YBar for Windows — Port Specification (C++ / komorebi)

This document specifies **ybar-win**: a native C++ implementation of YBar for
Windows 11 with first-class [komorebi](https://github.com/LGUG2Z/komorebi)
integration. It lives on the **`windows` branch of the YBar repository** — an
orphan branch with its own root history that never merges with `main`
(different toolchain, CI, and release cadence), conveniently checked out
side-by-side via `git worktree`. This spec is its founding document and also
stays on `main` as the contract of record between the two implementations.

It is written from a full dissection of the Swift codebase (every subsystem
mapped, every Apple API inventoried), research into the Windows platform
equivalents (Microsoft Learn, Windows Terminal AtlasEngine, wezterm, PowerToys,
yasb/zebar precedent), and wire-level research of komorebi v0.1.41 from its
source. File references like `PropertySetter.swift:…` refer to the YBar Swift
tree, which remains the reference implementation.

---

## 1. Product definition

**ybar-win is a separate product with a shared soul.** The engines diverge
(Swift/Metal/AppKit vs C++/D3D11/Win32); the *user contract* does not. A theme,
Lua config, or shell script written for YBar on macOS must run on ybar-win with
only OS-inherent edits (shell commands it shells out to, glyph fonts, WM
adapter). Concretely:

- Same single-binary model: `ybar.exe` is daemon and CLI client.
- Same wire protocol, command verbs, property namespace, event names, script
  environment contract, `--query` JSON shapes, and embedded Lua 5.4 API.
- komorebi replaces AeroSpace/yabai as the first-class workspace adapter.

### Non-goals (v1)

- Windows 10 support (Win11 22H2+ only; needed for `DWMWA_SYSTEMBACKDROP_TYPE`
  and simplifies DirectComposition assumptions). Win10 may work degraded; not
  tested.
- The `alias` component (macOS menu-bar-extra capture). Grammar accepted,
  creation returns a clear error (§10.6).
- Feature parity with macOS-26 Liquid Glass. `glass=on` maps to Acrylic (§7.6).
- Wayland/Linux, other WMs (GlazeWM etc. can integrate the AeroSpace way —
  config-side — but get no native provider in v1).

---

## 2. Decision record

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Language | **C++20**, MSVC, CMake + vcpkg | Native fit for COM/D3D; AtlasEngine/Terminal patterns lift near-verbatim; owner preference |
| D2 | Repo | **Orphan branch `windows`** in the YBar repo, worktree checkout | One repo/issue tracker; own root history so the two lines never merge; per-branch CI; themes+examples copied in, contract doc shared |
| D3 | Renderer | **D3D11** + DXGI flip-model composition swap chain + **DirectComposition**; HLSL compiled at runtime via `D3DCompile` | Only clean per-pixel premultiplied-alpha path (`WS_EX_NOREDIRECTIONBITMAP`); preserves "no shader toolchain at build time" |
| D4 | Text | **DirectWrite** full stack; **grayscale AA forced** | ClearType subpixel breaks the R8 coverage atlas and transparent composition |
| D5 | WinRT/COM | **C++/WinRT** (GSMTC media) + **WIL** (COM lifetime) | Header-only, MS-maintained |
| D6 | Lua | Vendored **Lua 5.4 built as C**, raw C-API bridge mirroring `LuaRuntime.swift` incl. the non-raising-trampoline invariant | `lua_error` longjmp through C++ frames skips destructors — same UB class the Swift bridge engineered around |
| D7 | IPC | **AF_UNIX** (Winsock, `afunix.h`), socket at `%LOCALAPPDATA%\ybar\` | Wire-format parity with macOS; komorebi proves AF_UNIX in production and uses the same location convention |
| D8 | komorebi | **Native `KomorebiProvider`** speaking the socket protocol directly (no Rust crate) | C++ can't link `komorebi-client`; protocol is simple (one JSON per connection, §11) |
| D9 | Space reservation | komorebi **`MonitorWorkAreaOffset`** handshake by default; **SHAppBarMessage appbar** as opt-in fallback for non-komorebi users | komorebi-bar precedent; double reservation (appbar + offset) must be impossible |
| D10 | Scripts | `sh -c` when `sh.exe` resolves (Git Bash / bundled **busybox-w32**), else PowerShell; `YBAR_SHELL` override | Every shipped config writes POSIX sh; komorebi users almost universally have Git installed |
| D11 | Icons | Keep `sf:`/`sf.` grammar; resolver maps names via shipped JSON table to **Segoe Fluent Icons**, bundled **fluentui-system-icons** font as fallback | SF Symbols are Apple-proprietary; grammar is the contract, artwork is swappable |
| D12 | JSON | **nlohmann/json** | `--query` output + komorebi State parsing; tolerant of unknown fields |
| D13 | Tests | **Catch2**, porting the ~90 platform-neutral Swift Testing contract tests | The Swift suite is the executable spec of the compat surface |

---

## 3. The compatibility contract (invariants)

Everything in this section is **byte-for-byte or behavior-for-behavior
identical** to the Swift implementation. The Swift test suite
(`Tests/YBarKitTests/`) encodes most of it; port those tests first and develop
against them.

### 3.1 Wire protocol (`WireFormat.swift`)

- Frame: `u32` little-endian payload length + payload, both directions. Max
  payload 8 MiB.
- Request payload: each argv token UTF-8 + `0x00`, one extra trailing `0x00`
  (double-NUL terminator). Decoder stops at first empty token.
- Reply: raw UTF-8; empty frame = empty reply. Replies starting `[!]` →
  client prints to stderr, exit 1; otherwise stdout, exit 0.
- Client timeout 5 s; server per-connection send/recv timeouts 2 s
  (Winsock `SO_RCVTIMEO`/`SO_SNDTIMEO` take a `DWORD` in ms, not `timeval`);
  one request/reply per connection; serial accept loop on a thread named
  `ybar-ipc`; listen backlog 16.
- Instance lock: the socket file is the lock. If it exists, ping with argv
  `["--ping"]` (1 s timeout); `"pong"` → "already running"; dead → delete file,
  rebind.

### 3.2 CLI grammar (`CommandParser.swift`, `CommandHandler.swift`)

All 19 verbs with identical usage/error strings: `ping, bar, default, add, set,
subscribe, trigger, animate, update, query, push, remove, move, reorder,
rename, clone, reload, hotload, exit`. Tokenizer: `--word` opens a domain
batch; tokens until the next `-`-prefixed token belong to it **except**
negative numbers (`-` followed by digit or `.`); `key=value` splits on the
first `=`; tokens before the first `--` are silently ignored; `-m/--message`
prefix stripped. `--animate <curve> <frames>` is message-scoped and applies to
subsequent `--set`/`--bar` batches; `--default` never animates. `--exit`
replies first, terminates ~0.15 s later.

### 3.3 Property namespace (`PropertySetter.swift`, `BarPropertySetter.swift`)

The complete dotted-path grammar, verbatim — including every
accepted-and-ignored sketchybar-compat key (`padding_top`, `space`,
`associated_space`, `mach_helper`, `font.features`, `popup.topmost`, …), the
color channel addressing (`.alpha/.red/.green/.blue/.hex`), `0xAARRGGBB`
colors, bool grammar (`on/off/true/false/yes/no/1/0` + `toggle` on bool
leaves), `width=dynamic` (-1 sentinel with measured-width animation seeding),
auto-enable of `background.drawing` on color set, lazy `gauge.*`/`image.*`
component attachment, and the exact `[!]`/`[?]` error string formats.

Windows-specific accepted no-ops: `notch_width`, `notch_offset`,
`notch_display_height` (no notched hardware — parsed, stored, never affect
layout), `wifi_ssid_prompt` (SSID needs no location grant from Win32 — but see
§10.4 for the 24H2 caveat), `font_smoothing`. No-op keys accept any value
without validation (their values are never read).

**Ambiguity rulings** (resolved 2026-08 after the compliance audit found the
spec's letter and the reference's behavior disagreeing):

- **`toggle` scope**: accepted on *every* boolean leaf, which is this
  document's letter. The reference rejects it on a handful of leaves
  (`scroll_texts`, `popup.horizontal`, `popup.auto_close`, `image.drawing`,
  `background.image.drawing`, `glass`, `slider.knob.drawing`) — an
  inconsistency, not a contract. Bar-level `toggle` stays restricted to
  `hidden` and `idle_inhibit`, where both agree.
- **`alias.color` / `alias.update_freq`**: accepted-and-ignored on any item
  (§3.3 wins over §10.6's error wording), so sketchybar configs carrying
  alias styling load cleanly on a platform that has no aliases. Creating an
  alias item still errors (§10.6).
- **"byte-compatible" `--query` output** (§3.6) means the same keys, order,
  and value *shapes*; JSON pretty-printer whitespace and number formatting
  are explicitly outside the guarantee (nlohmann writes `"key": v`,
  JSONSerialization writes `"key" : v`).
- **Case sensitivity**: enum-ish values (`toggle`, `dynamic`, `active`,
  `when_shown`, bar `position`/`topmost`/`display`/`reserve`) are matched
  case-insensitively — a superset of the reference, chosen because rejecting
  `TOP` helps nobody.

### 3.4 Events (`EventBus.swift`)

The 20 built-in events **in exact declaration order** (bit = `1 << index`,
`u64` mask, cap 64 total, custom events append):
`front_app_switched, space_change, display_change, system_woke,
system_will_sleep, mouse.entered, mouse.exited, mouse.clicked, mouse.scrolled,
volume_change, power_source_change, battery_change, wifi_change, system_stats,
mouse.exited.global, mouse.entered.global, modifier_change, app_launched,
app_terminated, media_change`. Order is a contract — `--query` exposes raw
`update_mask` values. The forced-query `--trigger` interception set is
identical: `volume_change, power_source_change, battery_change, wifi_change,
front_app_switched, display_change, system_stats, media_change`.

### 3.5 Script environment

`NAME`, `SENDER` (event | `routine` | `forced`), `INFO`, `BUTTON`
(`left|right|other`), `MODIFIER` (`shift|ctrl|alt|cmd|none`, priority
shift>ctrl>alt>cmd — **`cmd` maps to the Windows key**), `SCROLL_DELTA`,
`PERCENTAGE`, `CONFIG_DIR`, `BAR_NAME`, plus the per-event extras
(`CPU_USAGE/CPU_FRACTION/MEMORY_*/DISK_*_GB/THERMAL_STATE`, `MEDIA_*`,
`FOCUSED_WORKSPACE/PREV_WORKSPACE`). `NAME/SENDER/INFO` are applied last and
cannot be spoofed by `--trigger` extras. INFO payload shapes per event are
identical (e.g. `system_stats` = `{"cpu": N, "memory": N}` with the space after
the colon; `mouse.clicked` INFO = compact `{"button":"…","modifier":"…"}`).
`THERMAL_STATE` is always `nominal` on Windows (no public equivalent) — the
variable stays so scripts don't break.

### 3.6 `--query` JSON

All shapes byte-compatible modulo JSON number formatting: `bar`, `defaults`,
`events` (`{"name": {"bit": n, "notification": "(null)"}}`), `displays`
(keys `arrangement-id`, `frame{x,y,w,h}`, `scale`, `main`, `DirectDisplayID` —
key names verbatim; on Windows `DirectDisplayID` carries a stable numeric id
derived from the monitor device path hash, documented as platform-defined),
and per-item (geometry/icon/label/scripting/bounding_rects/…). Pretty-printed,
sorted keys, colors `0x%08x` lowercase. **Coordinate-space note:** `frame` and
`bounding_rects` values are y-down device-independent points on Windows (the
native convention); the macOS build reports AppKit y-up global points for
`frame`. Document this — do not convert.

### 3.7 Lua API (`LuaRuntime.swift` + prelude + sbar shim)

The whole surface: `ybar.bar/default/set/subscribe/delay/update/query_table/
trigger/push/exec/add_event/query/remove/animate/add/item`, item handles
(`h:set/subscribe/push/query`, `h.name`), nested-table flattening, valstr
coercion (booleans → `on`/`off`, integral floats → integer strings), the
16-trampoline raw bridge, registry-ref subscriptions keyed per item per
event, generation-guarded `exec`/`delay` completions, SENDER=forced →
`routine` handler fallback, Lua-first-then-shell dispatch, and the pure-Lua
`sketchybar` compat shim shipped verbatim. The Lua prelude is plain Lua source
and ships **byte-identical**. Bridge invariants preserved: no
`luaL_check*`/`luaL_error` in trampolines (longjmp/destructor UB), key-copy
before stringify in table walks, `lua_State` generation counter.

### 3.8 Animation

Eight curves with identical formulas (first-letter parsing `q/s/t/e/c/b/o`),
durations in **frames at 60 Hz** (= frames/60 seconds regardless of actual
refresh rate), same-key **retarget** semantics (YBar's deliberate divergence
from sketchybar queue-chaining), non-animated set cancels, `onComplete` only on
natural completion, colors lerped in linear light.

### 3.9 Layout & rendering behavior

Five-cursor layout (`left/right/center/q/e`; with no notch, `q` flows left and
`e` flows right from `width/2` — they remain useful anchors and must work),
fixed-width slot semantics with unclamped align slack, the sketchybar text
width formula **`width = (int)(glyphPathBounds.width + 1.5)`** over tight ink
bounds (§7.4), ink-vs-em vertical centering rules, marquee (cycle = ink+24pt,
duration frames/60), paint order (bar bg → brackets → per item shadow → bg →
image → icon → graph/slider/gauge → label; all quads → all triangles → all
glyphs), pixel snapping (origin and size rounded independently), hard offset
shadows (no blur — do not "improve"), `background.clip` holes (max 16),
graph right-to-left on right-side positions, gauge 270° dial with label
centered inside contributing zero width.

---

## 4. Branch layout

Root of the `windows` branch (`git worktree add ..\ybar-win windows`):

```
ybar-win/
  CMakeLists.txt            — C++20, MSVC, vcpkg manifest (nlohmann-json, wil, catch2)
  src/
    main.cpp                — argv → client | daemon (mirrors ybar/main.swift)
    app/                    — daemon lifecycle, message loop, config exec, hotload
    ipc/                    — wire format, server (accept thread), client, parser, handler
    model/                  — Item, Style, Components, Layout, PropertySetter, Serialize
    anim/                   — curves, scheduler (compositor-clock driven)
    render/                 — D3D11 device/swapchains, SceneBuilder, GlyphAtlas,
                              FontCache (DirectWrite), Instances (shared GPU ABI)
    win/                    — BarSurface (HWND+DComp), PopupSurface, DisplayManager,
                              MouseRouter, backdrop, appbar
    providers/              — audio, power, network, stats, media (GSMTC), workspace,
                              komorebi (subscription + work-area + commands)
    lua/                    — CLua vendored (C), bridge, prelude.lua (byte-copy)
  shaders/ybar.hlsl         — shipped as a resource file, D3DCompile at startup
  themes/                   — copied from YBar; komorebi variants of workspace widgets
  examples/
    komorebi-whkd/          — replaces yabai-skhd: pairing guide + whkd bindings
  tests/                    — Catch2 port of the Swift contract tests
  docs/WINDOWS-PORT.md      — this file (copy)
```

Binary name stays `ybar.exe`. **Instance name = basename of argv[0] with the
`.exe` extension stripped** — the Swift code's `lastPathComponent` would
otherwise poison the socket path (`ybar.exe_user.sock`) and config discovery
(`~/.config/ybar.exe/`). Renaming the binary (`ybar2.exe`) still yields an
independent instance.

---

## 5. Process model & lifecycle

- `main.cpp`: argv non-empty and not `-c/--config|-h|-v` → thin client
  (serialize argv → socket → print reply). Else daemon.
- Daemon boot order (mirrors `Daemon.swift`): bind socket (instance lock) →
  create hidden message-only window + per-display bar windows → start
  always-on providers (workspace, power, media, **komorebi if detected**) →
  wire EventBus + lazy providers → start 1 s routine timer (`SetTimer` or a
  timer queue posting to the UI thread) → start IPC accept thread → execute
  config → enter `GetMessage` loop.
- **Threading model** (replaces `@MainActor`): all model/state mutation happens
  on the UI thread. Worker threads (IPC accept, providers with COM callbacks,
  komorebi subscription reader) marshal via `PostMessage(WM_APP_*)` +
  per-request completion event for the synchronous IPC reply. This sidesteps
  the deadlock the Swift port analysis flagged (its `DispatchQueue.main.sync`
  hop relies on AppKit pumping the main queue). The IPC thread posts, waits on
  an event with the same 2 s timeout, then writes the reply.
- COM: UI thread is STA (`RO_INIT_SINGLETHREADED` /
  `CoInitializeEx(COINIT_APARTMENTTHREADED)`); audio/media callbacks arrive on
  MTA worker threads and marshal to the UI thread.
- Config discovery, identical order with `<name>` = instance name:
  `-c <path>` (with `~` → `%USERPROFILE%` expansion) →
  `%XDG_CONFIG_HOME%\<name>\` → `~/.config/<name>/` → `~/.<name>rc(.lua)`,
  `.lua` preferred per directory. `~/.config` works fine on Windows and keeps
  theme docs identical.
- Hotload: `ReadDirectoryChangesW` on the config **directory**
  (`FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NAME`), which sees in-place writes
  *and* atomic rename-saves — the dual vnode watch from macOS collapses to one
  watcher. Keep the 0.5 s trailing debounce and the 1.0 s post-reload
  suppression window verbatim (config runs write into the watched directory
  and would loop; the "drops saves within 1 s of a reload" tradeoff is
  documented behavior, not a bug).
- Shutdown (`--exit`, `WM_ENDSESSION`): zero the komorebi work-area offset
  (§11.4), stop IPC, destroy windows, exit 0.

### 5.1 IPC endpoint

`%LOCALAPPDATA%\ybar\<instance>_<user>.sock` (AF_UNIX, `SOCK_STREAM`;
`sun_path` limit 108 bytes — if exceeded, fall back to
`%TEMP%\<instance>_<user>.sock` and log). Access control: the socket file gets
an explicit DACL restricted to the current user SID (the macOS `chmod 0600`
is security-relevant — this is unauthenticated command execution). Delete
stale file before bind; `closesocket` not `_close`; no `SIGPIPE` on Windows
(`send` returns `WSAECONNRESET`).

**Cross-component coupling**: the theme switcher must use the same path. The
POSIX `scripts/ybar-theme` becomes `ybar-theme.ps1` (or a built-in
`ybar theme …` subcommand — preferred) preserving verbs, messages, and the
`~/.config/ybar/themes/` + `current-theme` state file layout.

---

## 6. Windowing

Per included monitor, `BarSurface` creates:

```
HWND  WS_POPUP | (borderless)
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP
      [+ WS_EX_TOPMOST per topmost setting]
 └─ IDCompositionTarget → visual → DXGI composition swap chain
    (BGRA8_UNORM + sRGB RTV, DXGI_ALPHA_MODE_PREMULTIPLIED, FLIP_SEQUENTIAL, 3 buffers)
```

- `WS_EX_NOACTIVATE` reproduces the non-activating panel: the bar receives
  mouse input but never steals focus. `WS_EX_TOOLWINDOW` = out of Alt-Tab
  (`.ignoresCycle`). There is **no click-through region** — matching macOS,
  the bar consumes all input over its frame; do not use `WS_EX_TRANSPARENT`.
- **topmost triad**: `on` → `HWND_TOPMOST`; `window` → `HWND_TOPMOST` but
  below popups (single z-band; the macOS floating-vs-status distinction has no
  Win32 analog — document); `off` → non-topmost at `HWND_BOTTOM`, re-asserted
  on `WM_WINDOWPOSCHANGING`, and **only useful when the strip is reserved**
  (komorebi offset or appbar) since maximized windows would otherwise cover
  it. Popups/tooltips: `HWND_TOPMOST` ordered above their bar.
- `sticky=on` (default): pin to all virtual desktops via
  `IVirtualDesktopManager`/`VirtualDesktopPinnedApps` when available; with
  komorebi, workspaces are komorebi's own concept and a topmost tool window is
  visible across them anyway — degrade gracefully if the undocumented pinning
  interface is missing. `sticky=off` = no pinning.
- DPI: manifest `PerMonitorV2`; scale = `GetDpiForWindow()/96`; handle
  `WM_DPICHANGED` like `viewDidChangeBackingProperties` (resize buffers,
  switch glyph-atlas scale). One `GlyphAtlas` per distinct scale, as on macOS.
  Popup scenes build at the **host surface's** scale: a fresh window's DPI
  comes from the monitor at its **creation position** — a popup created at
  default coordinates reports the primary monitor's DPI and only corrects via
  `WM_DPICHANGED` after being moved (same operational rule as macOS,
  different mechanism; creating popups directly at their target coordinates
  also works).
- Displays: enumerate `EnumDisplayMonitors`; the public contract stays the
  **1-based arrangement index** (primary = 1, then enumeration order);
  internally re-match monitors across `WM_DISPLAYCHANGE` by
  `QueryDisplayConfig` device path (EDID-stable), then rebuild debounced
  500 ms (the sledgehammer, kept). `display=active` = monitor of
  `GetForegroundWindow()`.
- `fullscreen_show`: prefer komorebi state (monocle/maximized container on
  that monitor) when the provider is live; else appbar `ABN_FULLSCREENAPP`
  when registered; else foreground-window-rect == monitor-rect heuristic
  (`SHQueryUserNotificationState` alone is unreliable for borderless-fullscreen
  games). Behavior contract unchanged: per-surface elevation to topmost while
  fullscreen is detected on *that* monitor.
- `hidden`, `shadow` (DWM shadow toggle), `margin/y_offset/height/position`
  math identical (all y-down native — the AppKit y-up conversions are simply
  deleted).
- Mouse: WndProc `WM_LBUTTONDOWN/UP`, `WM_RBUTTONUP`, `WM_MBUTTONUP`,
  `WM_MOUSEMOVE` + `TrackMouseEvent(TME_LEAVE)`, `WM_MOUSEWHEEL`
  (`GET_WHEEL_DELTA_WPARAM/120`, sign preserved). Click fires on button-up.
  Modifiers via `GetKeyState` mapped `shift>ctrl>alt>cmd(Win)`. Global
  popup-auto-close + `mouse.exited.global`/`modifier_change` need
  `SetWindowsHookEx(WH_MOUSE_LL / WH_KEYBOARD_LL)` — no permission prompts on
  Windows. UIPI caveat: a non-elevated process's low-level hooks do not
  observe input delivered to elevated windows, so popup auto-close and
  modifier tracking degrade while an elevated app has focus — acceptable; do
  not pursue uiAccess. Keep both warped-cursor defenses: any surface event marks the
  pointer inside; the 250 ms global-exit debounce re-verifies containment via
  `GetCursorPos` and is vetoed during slider drags.
- Popups: same lifecycle invariants — a popup panel counts as live only after
  its scene rendered; anchor math (host frame → screen coords, l/c/r align,
  below-bar for top position) is pure arithmetic over y-down coords.

### 6.1 Space reservation (replaces "windows avoid the menu bar")

New bar property (Windows extension, accepted-and-ignored by the macOS build):

```
--bar reserve=komorebi|appbar|off      (default: komorebi when detected, else off)
```

- `komorebi`: send `MonitorWorkAreaOffset` per included monitor (§11.4).
- `appbar`: register via `SHAppBarMessage` (`ABM_NEW/QUERYPOS/SETPOS`), for
  users without komorebi. Gets `ABN_FULLSCREENAPP` for free.
- The two modes are mutually exclusive by construction — double reservation
  (appbar + komorebi offset) reserves the strip twice.

---

## 7. Rendering

### 7.1 Device & swap chains

One `ID3D11Device` (+ immediate context) shared across surfaces; one
composition swap chain per surface via
`IDXGIFactory2::CreateSwapChainForComposition`
(`DXGI_FORMAT_B8G8R8A8_UNORM`, `DXGI_ALPHA_MODE_PREMULTIPLIED`,
`FLIP_SEQUENTIAL`, BufferCount 3, `DXGI_SCALING_STRETCH`), bound with
DirectComposition (`DCompositionCreateDevice → CreateTargetForHwnd →
CreateVisual → SetContent → Commit`). This is the canonical transparent
GPU-window recipe (Kenny Kerr, MSDN 2014; Qt uses the same).

Flip-model swap chains **reject `*_SRGB` backbuffer formats** (flip model is
restricted to R16G16B16A16_FLOAT / B8G8R8A8_UNORM / R8G8B8A8_UNORM /
R10G10B10A2_UNORM). sRGB encode is obtained by creating the render-target
view as `DXGI_FORMAT_B8G8R8A8_UNORM_SRGB` **over the UNORM backbuffer** — a
documented special exception to RTV format rules; no extra swap-chain flag is
needed in D3D11. The sRGB RTV is **mandatory**: shader output is
gamma-encoded on write and blending happens in linear, so instance colors
keep macOS-identical gradients — a plain UNORM RTV visibly changes them.
Recreate the RTV after every `ResizeBuffers`. Alpha mode is orthogonal:
premultiplied alpha goes through the same sRGB encode.

**DComp scaling (corrected after a live miss)**: a composition target composes
in the WINDOW's coordinate space, which is physical pixels for a PerMonitorV2
process — so a physical-pixel swap chain maps 1:1 with **no visual transform**.
Do NOT add a `96/windowDpi` counter-scale: it halves the scene, producing a
full-width window that paints only its left half. That failure is easy to
misread, because glyphs rasterized at 2× and displayed at 0.5× still *look*
correctly sized — only the geometry betrays it. Verify by sampling painted
pixels at the far edge of the monitor, never by eyeballing text size.
`YBAR_DCOMP_SCALE` overrides the factor for diagnosis.

### 7.2 Damage model & pacing (behavior contract)

DWM is a retained compositor: **no render loop at rest** — `setNeedsRender()`
coalesces model changes to one full-scene re-encode posted to the UI thread;
render + `Present(1,0)` only then. No partial damage — damage gates *whether*
a frame renders, never what is drawn. While animations or a marquee are
active, pace frames with the DXGI **frame-latency waitable object**
(`DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT`, `SetMaximumFrameLatency(1)`)
or `DCompositionWaitForCompositorClock`, on-demand start/stop exactly like the
CADisplayLink (the scheduler's `continuousDemand`/`reattach` discipline
carries over). Animation durations remain frames/60 seconds at any refresh
rate. Failed present / device-removed → 1 s retry, device-lost recreation.
Acceptance: PresentMon / Task Manager GPU shows ~0% while the bar is static.

### 7.3 Pipelines & shader

Three PSOs (quad, shape, glyph) sharing one blend state (`SrcBlend=ONE`,
`DestBlend=INV_SRC_ALPHA`, both channels), cull mode **NONE** (the unit-quad
strip winding is not guaranteed CCW), no MSAA. `shaders/ybar.hlsl` ships as a
resource and compiles at startup with `D3DCompile` (vs_5_0/ps_5_0). Ship
`d3dcompiler_47.dll` **app-local** next to `ybar.exe` (redistributable under
the Windows SDK license, ~4 MB): the System32 copy exists on all Win 10/11
machines but is only documented as supported for UWP apps — app-local is the
supported path for desktop apps and preserves the no-build-time-toolchain
property.

The MSL→HLSL translation is mechanical — validated against the shader source:
`[[vertex_id]]/[[instance_id]]` → `SV_VertexID/SV_InstanceID`; device pointer
vertex-pulling → `StructuredBuffer<QuadInstance>` in `t0`; `Uniforms` →
`cbuffer b1`; holes → `StructuredBuffer<Hole>` (keep the explicit `float3`
pad = 32-byte stride); `constexpr sampler` → static sampler (LINEAR, CLAMP);
`fwidth/dfdx/dfdy` → `fwidth/ddx/ddy`; `mix` → `lerp`; `atan2` argument order
identical; `SV_Position.xy` in the pixel shader gives top-left pixel coords
exactly like `[[position]]` (the hole-cutout math depends on this and ports
unchanged); Metal and D3D share NDC conventions so `to_clip` is untouched.
The GPU instance ABI (QuadInstance 112 B / GlyphInstance 64 B / ShapeVertex
32 B / Hole 32 B, flag bits, binding slots t0/b1/t0+t1 textures) is preserved
with static asserts. `cornerExponent` stays transmitted-but-unused, as on
macOS. The painted glass rim (`flagGlass`) ships with its exact constants;
`nativeGlassBackdrops` is always false on Windows.

### 7.4 Text (DirectWrite)

Model on Windows Terminal AtlasEngine + `lhecker/dwrite-hlsl`:

- **Shaping**: `IDWriteTextAnalyzer` (`GetGlyphs/GetGlyphPlacements`) with
  system font fallback via `IDWriteFontFallback::MapCharacters` — each mapped
  range is one run with its own `IDWriteFontFace`, mirroring the per-run
  CTLine walk. A custom `IDWriteFontFallbackBuilder` chain routes the icon
  font's PUA range first.
- **Raster into the same atlas**: mask page 2048² R8 via
  `IDWriteGlyphRunAnalysis::CreateAlphaTexture` with
  **`DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE`** (forced — ClearType 3×1 would
  break the R8 coverage model and transparent composition). Concretely:
  `IDWriteFactory2::CreateGlyphRunAnalysis` with
  `DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC` + grayscale antialias mode, then
  `CreateAlphaTexture(DWRITE_TEXTURE_ALIASED_1x1)` — despite the enum name
  this yields 8-bit antialiased coverage under grayscale mode (Skia:
  "DWRITE_TEXTURE_ALIASED_1x1 is now misnamed, it must also be used with
  grayscale"); never pass `DWRITE_RENDERING_MODE_ALIASED`, which produces
  bi-level output. Color page 1024²
  premultiplied BGRA8-sRGB via `IDWriteFactory4::TranslateColorGlyphRun`
  (COLR layers; `DWRITE_E_NOCOLOR` → monochrome path) rendered through
  D2D into a `GUID_WICPixelFormat32bppPBGRA` target. Shelf packer, 1 px
  padding, quarter-point size buckets, cache keys, no-eviction policy, and
  the stderr warning strings port verbatim.
- **Metrics — the load-bearing part**: reproduce
  `ShapedLine{width, ascent, descent, inkWidth, inkMinX, inkMinY, inkMaxY}`.
  `ascent/descent` from `DWRITE_FONT_METRICS × size/designUnitsPerEm`. Ink
  bounds: accumulate per-glyph ink boxes (design metrics or
  `GetAlphaTextureBounds`) advanced along shaped positions, then apply
  **exactly** `width = (int)(inkBounds.width + 1.5)`. Every padding and
  alignment in every ported config depends on this truncation. A dedicated
  parity test with golden values from the macOS build is required (§14).
- **Fonts**: spec grammar `"Family:Style:Size"` unchanged; empty family →
  **Segoe UI Variable** with the style-string→weight table
  (`ultralight…black` → `DWRITE_FONT_WEIGHT_*`); named families matched via
  `IDWriteFontCollection::FindFamilyName` + face-name string match (DirectWrite
  exposes face names, so `"Hack Nerd Font:Bold Italic:14.0"` resolves the same
  way). `WM_FONTCHANGE` clears the font/glyph caches (late-installed Nerd
  Fonts — same behavior as the CoreText registration notification). It must
  be handled in the **bar windows'** WndProc — message-only windows do not
  receive broadcast messages, so the hidden message window never sees it.
  It is also a convention honored by well-behaved font installers, not a
  system guarantee.

### 7.5 Icons & images

- `sf:<name>` (text) and `sf.<name>` (image source) grammar preserved. The
  resolver maps names through a shipped JSON table to Segoe Fluent Icons
  codepoints (generated from the Microsoft Learn table); unmapped names fall
  back to the bundled `fluentui-system-icons` font (MIT, redistributable),
  then to a placeholder glyph with a stderr note. Tinting via the mask page
  works unchanged.
- `app.<Name>` image sources resolve running-process icons:
  process enumeration → `QueryFullProcessImageNameW` → `SHGetFileInfoW(SHGFI_ICON)`
  (UWP apps: unwrap `ApplicationFrameHost` and read the package logo asset).
  New Windows-native source `exe.<path>` resolves an icon directly from a path
  — used by the komorebi workspaces widget (§11.6).
- File images decode through WIC (`IWICImagingFactory`), multi-res `.ico`
  picks the frame nearest `size × scale`; `spinner`/rotation re-raster via a
  small D2D helper (cache-key behavior identical).

### 7.6 Backdrops

`blur_radius>0` or `glass=on` → `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE,
DWMSBT_TRANSIENTWINDOW)` (Acrylic; Win11 22621+) + dark mode via
`DWMWA_USE_IMMERSIVE_DARK_MODE` (documented only to darken the frame; that it
also selects the dark backdrop variant is undocumented-but-stable behavior,
the same reliance wezterm ships); popups likewise when `popup.blur_radius>0`.
The undocumented `SetWindowCompositionAttribute` accent path is dead on Win11
— never used. **Per-item glass pills have no Windows analog**: item-level
`glass`/`blur_radius` render as the shader's painted glass rim + translucent
fills only. Rounded backdrop corners via `DWMWA_WINDOW_CORNER_PREFERENCE`
(popups) — the maskImage mechanism has no equivalent and isn't needed.

---

## 8. Core model

`model/` is a 1:1 port of `Items/` + `Animation/`: Item tree,
TextPart/BackgroundStyle value types, YColor (linear-light lerp), GraphState
ring buffer, SliderState, GaugeState, ImageState, PopupState, bracket
derivation and regex member expansion (**unanchored** substring matching —
`std::regex` ECMAScript `regex_search`, matching NSRegularExpression
semantics), five-cursor layout as a pure function with injected measurement,
ComponentGeometry (bracket unions, popup vertical/horizontal/wrap-flow
layouts, graph tessellation), Serialize, and the animation scheduler.

Deliberate fix over the Swift original: `Item.contentWidth` hardcodes
`backingScale: 2` for alias layout (`Item.swift:114`) — irrelevant once alias
is unsupported, but the port threads real per-monitor scale through
measurement anyway (Windows scales are commonly 1.0/1.25/1.5).

---

## 9. IPC & CLI details

- Env folding on `--trigger` (client side) generalizes the AeroSpace/yabai
  trick: `$AEROSPACE_FOCUSED_WORKSPACE`/`$AEROSPACE_PREV_WORKSPACE` →
  `FOCUSED_WORKSPACE=`/`PREV_WORKSPACE=`, every `$YABAI_*` → `<suffix>=`,
  **and every `$KOMOREBI_*` → `<suffix>=`** — never overriding explicit
  tokens. Costs nothing, keeps configs verbatim-portable in both directions.
- CLI hot path: every widget script shells `ybar --set …`; keep client startup
  lean (no COM init, no WinRT, static CRT) — target < 10 ms per invocation.
- `--add event <name> [notification]`: the second argument (macOS distributed
  notification binding) is **accepted and ignored** with a one-time stderr
  note. Custom events remain fully functional via `--trigger`. (A future
  named-pipe broadcast binding may reuse the slot; out of scope v1.)

---

## 10. Providers

| Provider | Windows implementation | Notes |
|---|---|---|
| Workspace (front app) | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, WINEVENT_OUTOFCONTEXT)` → exe FileDescription (unwrap `ApplicationFrameHost` for UWP) | Always on; no permissions. komorebi's `FocusChange` events enrich but the hook works WM-less |
| space_change | komorebi provider (§11); without komorebi: no-op | INFO stays `""` |
| system_woke / system_will_sleep | `WM_POWERBROADCAST`: `PBT_APMRESUMEAUTOMATIC` / `PBT_APMSUSPEND` (+`RegisterSuspendResumeNotification` for modern standby) | |
| app_launched / app_terminated | From komorebi `Show`/`Destroy` window events when available; else 2 s process-snapshot diff (`EnumProcesses`) | **Semantics change**: window-scoped with komorebi (background processes invisible); WMI tracing needs admin — rejected. Document. |
| Power | `GetSystemPowerStatus` + `RegisterPowerSettingNotification(GUID_ACDC_POWER_SOURCE, GUID_BATTERY_PERCENTAGE_REMAINING)` → `PBT_POWERSETTINGCHANGE` | Push, no polling. `"AC"`/`"BATTERY"` strings + dedupe/forced split preserved; the third source condition `PoHot` (UPS) maps to `"AC"` |
| Audio | `IMMDeviceEnumerator` → `IAudioEndpointVolume` (+`IAudioEndpointVolumeCallback`), `IMMNotificationClient::OnDefaultDeviceChanged` re-arm | Callbacks marshal to UI thread. Muted → 0, integer percent |
| Network | `NotifyNetworkConnectivityHintChange` (or `INetworkListManager` events); SSID via `WlanQueryInterface(wlan_intf_opcode_current_connection)` | **Win11 24H2 gates SSID behind Location privacy** — degrade to `"connected"` exactly like macOS-without-authorization; `wifi_ssid_prompt=on` opens `ms-settings:privacy-location` |
| SystemStats | `GetSystemTimes` deltas (busy = (kernel−idle)+user), `GlobalMemoryStatusEx` (Total−Avail)/Total; `GetDiskFreeSpaceExW` for `DISK_*_GB` | Microsoft explicitly recommends this over PDH for ≥1 Hz sampling. Same 2 s interval, 0–100 contract |
| Media | **GSMTC** (`GlobalSystemMediaTransportControlsSessionManager`, C++/WinRT): `CurrentSessionChanged` + `MediaPropertiesChanged` + `PlaybackInfoChanged` → `media_change` with `MEDIA_APP/STATE/TITLE/ARTIST/ALBUM` | Strict superset of the macOS distributed-notification hack: covers Spotify, browsers, most players, plus artwork/seek/transport for a future now-playing popup. `MEDIA_APP` carries the session's app id — scripts matching `"Music"|"Spotify"` need the documented mapping table. Cached-env replay on reload preserved. Fails only under session-0 (not applicable) |
| Clock/routine | 1 s timer on UI thread, tolerance semantics via timer coalescing | |

### 10.1 ScriptRunner

Resolution order for the interpreter of `script`/`click_script`/`ybar.exec`
strings: `%YBAR_SHELL%` if set → `sh.exe` on PATH (Git Bash) → Git for
Windows `usr\bin\sh.exe` located via the `GitForWindows` registry
`InstallPath` (HKCU then HKLM — Git's installer never adds sh to PATH, and
an Explorer-launched daemon otherwise fell back to PowerShell, where every
sh-quoted theme command breaks; Git's sh does NOT self-prepend `/usr/bin`
for `sh -c`, so the shell's directory joins the exe dir in the child PATH
prepend — that is where tr/awk/coreutils live) → bundled
`busybox64.exe sh` → `powershell.exe -NoProfile -Command` (last resort, with a
one-time stderr warning that POSIX configs will break). Always
`<shell> -c <script>` semantics, cwd = config dir, 60 s kill
(`TerminateProcess` — note: child *trees* aren't killed on macOS either; a Job
Object here would actually fix that latent bug, do it), fire-and-forget, PATH
prepended with the `ybar.exe` directory and the resolved shell's directory
(`;` separator). The exec pipe is
drained concurrently with the child (same >64 KB deadlock exists with
anonymous pipes). Config scripts: no chmod (no exec bit), dispatch by
extension — `.lua`/`.jsonc` in-process, anything else through the resolved
shell. Lua's `io.popen`/`os.execute` go through `cmd.exe` (CRT `_popen`) —
document that these two escape the shell decision.

### 10.6 Alias

`--add alias` and `ybar.add("alias", …)` return
`[!] alias items are not supported on Windows`; `alias.*` property sets on
nonexistent aliases keep the standard error; `--query` never reports
`type=alias`. Rationale: menu-bar extras don't exist; tray icons are toolbar
buttons inside Explorer with no per-icon capture API. A future tray widget
(UIA over `TrayNotifyWnd` + `Windows.Graphics.Capture` crop) may revive the
grammar — explicitly out of scope v1.

---

## 11. komorebi integration (the centerpiece)

All wire facts below verified against komorebi **v0.1.41** source (May 2026;
release cadence roughly quarterly: 0.1.38 Sep'25, 0.1.39 Dec'25, 0.1.40
Feb'26, 0.1.41 May'26).

### 11.1 Transport

- komorebi's data dir: `%LOCALAPPDATA%\komorebi\`.
- **Command channel**: AF_UNIX socket `%LOCALAPPDATA%\komorebi\komorebi.sock`.
  Client convention (komorebi-client): one connection per message — connect,
  write one JSON-serialized `SocketMessage`, no delimiter, close (1 s write
  timeout). The daemon actually reads the stream **line-wise**, so batching
  newline-separated messages on one connection is also legal (`send_batch`
  does). Queries (`State`, `GlobalState`, `Query(…)`): write,
  `shutdown(SD_SEND)`, read reply to EOF.
- **`SocketMessage` encoding**: serde *adjacently* tagged
  (`#[serde(tag="type", content="content")]`) —
  `{"type": "<Variant>", "content": <payload>}`; tuple-variant content is a
  JSON array; unit variants are `{"type": "State"}` with no content key
  (komorebic generates exactly these).
- **Subscription**: the *subscriber* creates a listener AF_UNIX socket at
  `%LOCALAPPDATA%\komorebi\<name>` — the name is the file name **verbatim, no
  `.sock` appended** (komorebi-bar uses extension-less `komorebi-bar-<word>`;
  we use `ybar.sock` with the extension as part of the chosen name) — deletes
  any stale file first, then sends
  `{"type":"AddSubscriberSocket","content":"<name>"}` to `komorebi.sock`.
  For each event, komorebi **connects to the subscriber socket, writes one
  JSON `Notification` (no newline), and closes** — so framing = accept one
  connection, read to EOF, parse one JSON document. komorebi prunes a
  subscriber (and deletes its socket file) when **connecting to it fails** —
  keep the listener accepting or you are silently unsubscribed on the next
  event. (`subscribe-pipe` also exists — named pipe `\\.\pipe\<name>`,
  newline-delimited JSON, the yasb/Python route — but the socket route keeps
  one IPC mechanism across the codebase.) Subscribe with
  `AddSubscriberSocketWithOptions(name, {filter_state_changes: true})` to
  receive only state-changing notifications — komorebi-bar does.

### 11.2 Notification & State schema

Every notification is the **full state snapshot**:

```json
{ "event": { "type": "<NotificationEvent variant>", "content": … },
  "state": { …full State… } }
```

- `NotificationEvent` = `WindowManager(WindowManagerEvent) | Socket(SocketMessage)
  | Monitor(…) | VirtualDesktop(…)` — but the outer enum is
  **`#[serde(untagged)]`**: those four names never appear on the wire; `event`
  is directly the inner enum's JSON. `WindowManagerEvent`, `SocketMessage`,
  and `MonitorNotification` are each adjacently tagged (`type`/`content`);
  `VirtualDesktopNotification` has **no tag** — its unit variants serialize as
  bare strings (`"event": "EnteredAssociatedVirtualDesktop"`), so the parser
  must accept `event` being a plain string, not only an object.
- `WindowManagerEvent` variants (tag/content): `FocusChange, Show, Hide,
  Destroy, Cloak, Uncloak, Minimize, MoveResizeStart, MoveResizeEnd,
  MouseCapture, TitleUpdate` (payload `(WinEvent, Window)`) and
  `Manage, Unmanage, Raise` (payload `Window`).
- `State`: `monitors` is a `Ring` — `{"elements":[…], "focused": n}` — of
  Monitor; plus `is_paused`, `work_area_offset`, `monitor_usr_idx_map`, ….
- `Monitor`: `id, name, device, device_id, serial_number_id, size,
  work_area_size, work_area_offset, workspaces (Ring), workspace_names`.
- `Workspace`: `name` (nullable), `containers (Ring)`, `monocle_container`,
  `maximized_window`, `floating_windows` (**a `Ring<Window>`** —
  `{"elements":…,"focused":n}`, not a plain array), `layout`, `tile`, ….
- `Window` serializes as `{"hwnd", "title", "exe", "class", "rect"}` — `exe`
  gives the process image name directly, which is everything the workspaces
  widget needs for app icons/glyphs. On lookup failure `title`/`exe`/`class`
  contain literal `"could not get window …"` fallback strings, not null —
  treat those as unknown.
- `Rect` = `{left, top, right, bottom}` where **`right` and `bottom` are
  width and height**, not edge coordinates (komorebi subtracts when
  converting from Win32 `RECT`; komorebi-bar itself misuses `size.right` as
  an x-coordinate — do not copy that). Values are physical pixels.

Focused workspace = `monitors.elements[monitors.focused]
.workspaces.focused`; workspace *name* when non-null, else 1-based index as
the display string. Monocle/maximized state per workspace feeds
`fullscreen_show`.

Parsing rule: **tolerant** — unknown fields ignored, missing optionals
defaulted; the schema has no formal stability guarantee (no breaking changes
documented in the last five releases, but pin the tested version in CI and
re-validate per release).

### 11.3 KomorebiProvider (daemon-side, always attempted at boot)

- Detect komorebi: try `komorebi.sock` connect (also poll lazily every 15 s
  when absent so a bar started before komorebi attaches itself).
- Subscribe as `<instance>` (i.e. socket `%LOCALAPPDATA%\komorebi\ybar.sock`;
  a renamed ybar instance gets its own). Reader thread: accept → read-to-EOF
  → parse → `PostMessage` to UI thread.
- **Reconnect** (komorebi-bar's pattern, one fix): a zero-byte read / accept
  failure ⇒ komorebi died; loop re-registration every 1 s until it succeeds,
  then re-apply the work-area offset (§11.4) and re-publish state.
  Re-register with `AddSubscriberSocketWithOptions` — komorebi-bar re-sends
  the plain variant here and silently loses its state filter after a
  reconnect; don't copy that.
- Events published on the YBar bus:
  - `space_change` (built-in) + **`komorebi_workspace_change`** (registered by
    the provider as a custom event) with env
    `FOCUSED_WORKSPACE=<name-or-index>`, `PREV_WORKSPACE=…`,
    `FOCUSED_MONITOR_INDEX=<1-based>`, INFO = focused workspace display
    string — fired on any notification whose focused monitor/workspace
    changed. Themes keep the AeroSpace pattern (subscribe, read
    `env.FOCUSED_WORKSPACE`) verbatim.
  - `front_app_switched` from `FocusChange` (title/exe in hand) — deduped
    against the WinEventHook source so items see one event.
  - `app_launched`/`app_terminated` from `Show`/`Destroy` (window-scoped,
    §10 table).
  - Raw passthrough: the full notification JSON is cached; a
    `--query komorebi` extension verb returns the last State for
    scripts/Lua (cheap — it's already parsed).
- **Forced-query** entries added: `komorebi_workspace_change` re-reads cached
  state (or sends `{"type":"State"}`) so `ybar --trigger
  komorebi_workspace_change` replays current state at config boot, mirroring
  the AeroSpace boot-population idiom.

### 11.4 Work-area reservation handshake

On start / bar-height change / monitor change / komorebi reconnect, when
`reserve=komorebi`:

```json
{"type":"MonitorWorkAreaOffset","content":[<monitor_idx>, {"left":0,"top":H,"right":0,"bottom":H}]}
```

per included monitor. **Both `top` and `bottom` are `H`**: komorebi applies
`top += offset.top; bottom -= offset.bottom` where `bottom` is the work-area
*height* — `top` alone would shift the area down without shrinking it,
pushing tiles `H` px past the bottom of the screen (komorebi-bar sets both,
`bar.rs:503`). `H` = **physical pixels** of
`(height + y_offset) × monitor scale` (komorebi rects are physical;
komorebi-bar's un-scaled constant is a known limitation, we do better) and
`monitor_idx` is komorebi's index for the monitor **matched via State
`device_id`/geometry**, not ybar's arrangement index. On graceful exit
(`--exit`, `WM_ENDSESSION`): send the same message with a zero rect.
Known limitation (komorebi-bar has it too): a crashed bar leaves the offset
until komorebi reloads its config — document `komorebic restore-windows` /
config reload as the fix, and re-zero on next ybar start before applying.

### 11.5 Click commands

Two supported forms:

- **Compat (themes port verbatim)**: `click_script = "komorebic focus-workspace 2"`
  — shells out, works everywhere.
- **Native (no process spawn)**: Lua `ybar.komorebi({type="FocusMonitorWorkspaceNumber",
  content={0, 2}})` and CLI `ybar --komorebi '<json>'` — the daemon writes the
  message straight to `komorebi.sock`. Useful messages: `FocusWorkspaceNumber(n)`,
  `FocusMonitorWorkspaceNumber(m, n)`, `FocusNamedWorkspace(s)`,
  `CycleFocusWorkspace(dir)`, `TogglePause`. This is a ybar-win extension;
  the macOS build rejects the verb.

### 11.6 Workspaces widget & pairing example

`themes/*/items/workspaces.lua` gets a komorebi variant with the exact
structure of the AeroSpace one (pills, focused highlight, reveal/collapse
animation, app glyphs) but **event-driven with zero polling**: the provider's
cached state replaces all three `aerospace list-*` CLI calls (enumeration =
`workspaces.elements` per monitor; visible = non-empty ∪ focused, where
non-empty = `containers.elements` non-empty, or `monocle_container`/
`maximized_window` set, or `floating_windows.elements` non-empty; app names
from `Window.exe` mapped through `helpers/app_icons.lua`).
Click = `komorebic focus-workspace <idx>` (compat form). Note komorebi
workspaces are **per-monitor and dynamic** — re-enumerate pills on state
notifications, not only at config load.

`examples/komorebi-whkd/` replaces `examples/yabai-skhd/`: komorebi.json
fragment (bars should NOT also set `global_work_area_offset` when
`reserve=komorebi` — ybar sends it), whkd bindings firing
`ybar --trigger …` (mode-pill pattern like skhd modes), and the pairing
walkthrough. No SIP/scripting-addition section — komorebi needs no OS
tampering.

### 11.7 Licensing

komorebi is under the **Komorebi License 2.0.0** (PolyForm-Strict derivative:
personal use is a permitted purpose; source-only redistribution; the license
grants no commercial purpose — commercial users need the separately offered
Individual Commercial Use License, per the komorebi README). ybar-win **does not link, bundle, or redistribute any
komorebi code** — it talks to a socket owned by a program the user installed
under their own license. Public precedent: yasb and zebar integrate the same
way. GPL-3.0 for ybar-win is therefore unaffected. (Not legal advice; note in
the README's third-party section.)

---

## 12. Config, Lua, themes

- LuaRuntime port per §3.7. `LUA_USE_MACOSX` is simply absent; `luaconf.h`
  auto-detects `_WIN32`. Lua compiled as C, statically linked.
- The JSONC declarative tier ports verbatim (`JSONCConfig.swift` is pure
  logic; the one CoreFoundation bool-sniff becomes a `nlohmann::json`
  `is_boolean()` check — booleans must stringify `on`/`off`, not `1`/`0`).
  Sorted-key emission is a tested contract.
- Themes: theme model (directory + entry-point search `ybarrc.lua` →
  `ybar.jsonc` → `ybarrc.jsonc`, `~/.config/ybar/themes/`, `current-theme`
  file, install-from-git) ports; shipped themes get komorebi workspace
  widgets and `ms-settings:` deep links (`ms-settings:sound`,
  `ms-settings:batterysaver`, `ms-settings:network-wifi`) replacing
  `x-apple.systempreferences:` clicks; `osascript` media/volume snippets are
  obsolete — media is native (GSMTC) and volume goes through the audio
  provider or a `ybar --set`-driven slider.

---

## 13. Packaging & distribution

- **winget manifest + scoop bucket** (komorebi precedent for a CLI+daemon
  hybrid); chocolatey on demand. Prebuilt zip — SmartScreen warns but no
  Gatekeeper-style forcing function; `signtool` signing optional later.
- Static CRT (`/MT`) → single `ybar.exe` + `shaders/` + `themes/` payload.
  No TCC/codesign/bundle apparatus — that entire macOS surface evaporates.
- Identity: `AppUserModelID = "YBar.YBar"` (taskbar/notification identity;
  successor to `com.ybar.YBar`).
- Autostart: `ybar autostart enable|disable` writes/removes
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (visible in Task
  Manager's Startup Apps, user-toggleable). Crash-restart semantics (macOS
  LaunchAgent `KeepAlive.SuccessfulExit=false`) via an optional Task Scheduler
  recipe in docs; `ybar --exit` remains the only sanctioned stop.
- Build dir: out-of-tree default (`%LOCALAPPDATA%\ybar-build`) — the repo may
  live in OneDrive-synced folders (this one does); same hazard class as the
  iCloud/xattr issue that motivated the macOS scratch path.

---

## 14. Testing & CI

- Port the ~90 platform-neutral tests (wire framing, tokenizer, colors +
  linearization, curves, FontSpec parsing, layout invariants incl. q/e and
  width=dynamic sentinel, property paths, defaults, event bits +
  NAME/SENDER/INFO protection, JSONC translation with sorted output, glyph
  clip UV-remap math, Lua end-to-end with headless BarManager) to Catch2.
  Keep the daemon constructible **headless** (no window creation in
  constructors) so Lua tests run in CI — the Swift code preserves this seam
  deliberately.
- **Text-metric parity suite**: golden `ShapedLine` values (width per the
  +1.5 formula, ink bounds) exported from the macOS build for a fixed test
  font shipped in the repo; DirectWrite must match integer-exactly.
- **komorebi protocol tests**: recorded notification/State JSON fixtures from
  v0.1.41 (checked in) parsed by the provider; a canary CI job runs against
  komorebi's latest release to catch schema drift.
- CI: GitHub Actions `windows-latest`, CMake + vcpkg cache; PresentMon-based
  idle-GPU smoke test on a self-hosted runner is aspirational, manual
  acceptance otherwise.

---

## 15. Milestones

- **W0 — protocol spike** (de-risk): AF_UNIX server/client + wire format
  round-trip against the *macOS* test vectors; komorebi subscribe + State
  parse + `MonitorWorkAreaOffset` round-trip on a live komorebi; D3DCompile of
  the translated HLSL. All three are days-scale.
- **W1 — skeleton**: bar window per monitor (DComp premultiplied swap chain,
  correct styles), transparent clear + SDF bar background, `--bar color=…`
  over IPC, idle GPU ≈ 0.
- **W2 — items & text**: DirectWrite stack, atlas, five-cursor layout,
  `--add/--set/--query`, icon mapping table, metric-parity suite green.
- **W3 — events & scripts**: EventBus, ScriptRunner (shell resolution),
  providers (power/audio/stats/network/front-app), mouse events, config
  exec + hotload, routine timer.
- **W4 — komorebi**: provider, work-area handshake, workspaces theme variant,
  `examples/komorebi-whkd`, `--komorebi` verb.
- **W5 — animation & components**: scheduler on compositor clock, curves,
  graphs/sliders/gauges/brackets/popups/tooltips, marquee.
- **W6 — polish & ship**: Lua runtime + shim, JSONC tier, GSMTC media +
  now-playing widget, Acrylic backdrops, winget/scoop, `ybar theme`
  subcommand, ported themes.

### Implementation status (as of 2026-08-11, all live-verified on hardware)

**Done** — W0 (wire + komorebi protocol + HLSL, incl. a live State round-trip);
W1 (bar windows, DComp with the §7.1 DIP counter-scale, SDF background);
W2 partially (DirectWrite stack, atlas, layout, full CLI — advance-based
widths, no icon mapping yet); W3 mostly (EventBus, ScriptRunner, mouse +
click_script, config exec/JSONC/hotload/--reload, power/stats/front-app
providers, routine timer); W4 fully (subscription with reconnect,
workspace-name events, `{top:H,bottom:H}` offset zeroed on exit,
`--komorebi` verb); W5 partially (scheduler with retarget semantics on an
on-demand compositor-clock frame pump — `DCompositionWaitForCompositorClock`
on a worker signaling an auto-reset frame event, consumed by an
input-priority `PeekMessage`/`MsgWaitForMultipleObjectsEx` main loop that
drains ALL pending messages before each frame. The event, not PostMessage,
is load-bearing: posted messages outrank hardware input in GetMessage, so a
posted 120 Hz frame stream starved clicks whenever render time approached
the budget — popups visibly lagged their opening click. Animations and
marquees run at the display's real refresh rate instead of the ~64 Hz a
16 ms WM_TIMER quantizes to — live-verified end to end: with the media
marquee on screen, the YBAR_DEBUG frame trace reads 119.5 fps sustained
through full re-encode + Present on the 120 Hz reference panel; the
scheduler and marquee are time-based, so pace changes smoothness only —
graphs/sliders(render)/gauges).

**Also done since**: the embedded Lua runtime (vendored 5.4.8, byte-identical
prelude, single-funnel trampolines, generation-guarded exec/delay, Lua-first
dispatch) — live-verified with in-process closures driving the komorebi
workspace pill and the CPU gauge. An in-tree **YTile provider** extension
mirrors the komorebi update flow (fires `komorebi_workspace_change` for
config compatibility); its wire contract is `docs/YTILE-IPC.md` in the
sibling YTile repo (see the YTile parity paragraph below). **Popups + tooltips**
(§3.9): vertical/horizontal/wrap layouts, per-host panels, WH_MOUSE_LL
outside-click auto-close, press-on-bar-closes-others, 600 ms tooltip dwell —
live-verified (panel screenshot, auto-close state flip, tooltip window
enumeration).

**Compliance audit (2026-08)**: four reviewers checked 387 spec claims across
the implemented subsystems against this document and the Swift reference. The
Lua prelude was confirmed byte-identical. 10 contract breaks and ~40 minor
divergences were found and fixed in one batch — the load-bearing ones being a
dangling-reference animation path (clip/wrap_width/gradient_color/fill_color),
unmasked targeted mouse dispatch, batch-abort on the first bad token, a
missing socket DACL, ANSI argv, boot order (the instance lock now binds
first), the komorebi zero-byte-read reconnect, and the missing 60 s script
watchdog. Regressions live in `tests/audit_regression_tests.cpp`.

**Also done**: the **`sf:` icon resolver + image pipeline** (§7.5) — SF-name →
Segoe Fluent Icons table with progressive dotted fallback and a placeholder +
one-time warning for unmapped names, runtime icon-font selection, WIC decode
for file paths, shell icons for `app.<Name>` / `exe.<path>`, color-page
uploads with source@size caching, and leading/trailing (`align=r`) emission.
Live-verified: nine symbols, the placeholder path, and Explorer's shell icon
rendering on the bar.

**Also done**: **text fidelity** (§3.9, §7.4) — tight-ink measurement via
per-glyph DirectWrite design metrics unioned along the pen (there is no
`useGlyphPathBounds` equivalent), the `(int)(ink + 1.5)` truncation applied to
real ink, ink-centered single-glyph icons, marquee scrolling with the frame
clock gated on `continuousDemand`, fixed-width glyph clipping with UV remap,
`background.clip` holes, highlight colors, text shadows, and bracket
backgrounds (bracket frames are now derived post-layout, which also enables
bracket hit-testing). Live-verified: bracket pill, a marquee scrolling across
two captured frames, and a clip hole. **Open on the §14 gate**: golden values
exported from a macOS run — the accumulation math has headless tests, but
cross-platform pixel equality is still unproven.

**Also done**: **the remaining providers** (§10) — audio over WASAPI endpoint
volume with default-device re-arm, media over GSMTC on a dedicated MTA thread
(the UI thread is an STA for WIC, and every GSMTC entry point blocks on an
`IAsyncOperation`, which deadlocks an STA), network connectivity + WLAN SSID
degrading to `"connected"` behind 24H2's Location gate, `app_launched` /
`app_terminated` from komorebi `Show`/`Destroy` with a Toolhelp snapshot-diff
fallback, `modifier_change` on a lazily-armed `WH_KEYBOARD_LL` hook that reads
modifier state only, and the global mouse events over the union of every ybar
window. App display names now come from the executable's `FileDescription`
with the `ApplicationFrameHost` unwrap for UWP; `wifi_ssid_prompt=on` opens
`ms-settings:privacy-location`. Every provider arms on first subscription.

**Also done**: **windowing robustness** (§6) — debounced `WM_DISPLAYCHANGE`
rebuilds (forwarded from the bar windows, which a message-only window never
receives), `WM_DPICHANGED`, `topmost=off` re-assertion on
`WM_WINDOWPOSCHANGING`, `fullscreen_show` per-surface elevation from
foreground-rect geometry, `reserve=appbar` via `SHAppBarMessage`, `sticky=on`
following the active virtual desktop through the documented
`IVirtualDesktopManager` (true pinning needs an undocumented, build-fragile
interface — it degrades with a one-time warning), `idle_inhibit`, popup and
tooltip clamping into the anchor's monitor, slider dragging, `--animate` on
`--bar` keys, `width=dynamic` seeding, and komorebi lazy re-detect. Item
frames are now recorded **per surface**, which fixed a real multi-monitor bug:
`layout()` writes `item.frame` in place and ran once per surface, so clicks on
monitor 2 hit-tested against monitor 1's geometry whenever the two differed in
width, and `bounding_rects` reported one monitor's rects under every display
key.

**Also done**: Acrylic backdrops (§7.6) for bars and popups, `ybar theme
list|current|use`, `ybar autostart enable|disable|status`, the
`AppUserModelID`, the shipped `examples/catppuccin-komorebi` theme, and CI
packaging of `examples/` + app-local `d3dcompiler_47.dll`.

**Live-verified on a 2880×1800 200 % display** (build `479c6dc`): WASAPI
volume tracked six volume-up steps 0 % → 12 %; the network provider resolved
the real SSID; `modifier_change` reported `ctrl` for a synthetic key press;
`app_launched` fired with a `FileDescription` name (process-scoped, since
komorebi was not running); `--animate linear 60 --bar height=60` interpolated
32 → 44.8 → 60; `width=dynamic` animated 300 → natural and restored the −1
sentinel on completion; a synthetic drag to a 200 pt track's midpoint set the
slider to 50.5 %; and the shipped theme populated every item. Two bring-up
fixes came out of it: COM is now initialized before the first surface (sticky
pinning was failing at boot), and the icon map gained `wifi.slash` /
`square.grid.2x2`.

A second live pass covered the rest: `reserve=appbar` moved the shell work
area's top edge 0 → 34 (exactly the bar height) and restored it on
`reserve=off`; `fullscreen_show` added `WS_EX_TOPMOST` to a `topmost=off` bar
while a window covered the monitor and dropped it again when that window
closed; and the media provider published `MEDIA_TITLE`/`MEDIA_STATE` for a real
SMTC session, with `--trigger media_change` replaying the cached env after the
label was cleared — the reload-mid-song contract. That pass also caught
`front_app_switched` still using the old exe-basename resolution, so packaged
apps reported `ApplicationFrameHost`; it now goes through the same
FileDescription + frame-host unwrap as the app-lifecycle events.

**Also done**: shipping (§13) — a tagged `win-v*` release workflow that
publishes a self-contained zip and prints its SHA256, winget manifests
(`winget validate` passes) and a scoop manifest with `checkver`/`autoupdate`
under `packaging/`, and a user-facing README covering install, themes, the
komorebi contract, the event list, the Windows-specific behaviours, and a
macOS-config porting table.

**Second audit** (post-slice-10 code): a 76-agent adversarial pass — six
dimension finders (COM/WinRT lifetimes, provider contract, windowing,
animation/input state machines, daemon wiring, ship/verbs), two refuters per
finding — confirmed 33 findings, all fixed: UAF-class races in the audio and
media providers and the komorebi dedupe state, a dangling block-scoped bar
animation context and a stack-local routed through the scheduler, the appbar
registered with no callback message (every ABN_* lost) and repositioned to
un-negotiated frames each frame, popups anchored to the wrong surface on
mixed-width monitors and frozen at creation DPI, missing SetCapture on
slider presses, `--trigger battery_change` also firing power_source_change,
the reload-mid-song media replay missing, reserve changes never detaching
komorebi, `ybar theme use` being write-only (config discovery now honors
`current-theme` for the default instance; `ybar theme reset` clears it), the
winget portable symlink breaking every exe-relative lookup, and more. A
three-lens review of the fix commit itself then confirmed 8 regressions the
fixes introduced (arm serialization, teardown orderings, drag-release
consumption, `\\?\UNC\` path mangling, instance hijack via current-theme) —
also fixed. One deliberate skip, now documented in place: slider hit-mapping
clamps align slack while the emit side is unclamped, because the Swift
reference has the identical asymmetry.

**Third live pass** (audited build): the reworked providers were re-verified
on screen (volume/SSID/battery/clock populate; `--trigger battery_change`
leaves a power-only subscriber untouched while `--trigger
power_source_change` fires it; a bare media trigger with an empty cache
dispatches nothing; a bare `ybar` start picked the theme up from
`current-theme`). The `WM_DISPLAYCHANGE` sledgehammer was exercised by
posting the message to a bar window: forward → 500 ms debounce → full
teardown/recreate (new hwnd), rebuilt bar painting uniformly at
x=5/1440/2875 with providers still answering. Sticky pinning was tested with
a synthetic Win+Ctrl+D — and FAILED: on a freshly created empty desktop the
only windows belong to the shell (present on every desktop), so naming the
current desktop via the foreground window cannot work. The follow now reads
Explorer's `CurrentVirtualDesktop` registry GUID (verified present on this
build whenever a second desktop exists) with the foreground trick as
fallback; the retest shows the bar full-width on a fresh desktop within one
follow tick.

**Flagship replication** (the goal the port was aimed at): the default macOS
setup — `examples/sketchybar-glass`, the Liquid Glass restyle over the full
sketchybar port, ~2,500 lines of Lua — runs on ybar-win, live-verified
against a real komorebi session. The compat shim and glass overlay ported
with zero runtime changes (the 2,300-line config loaded with an empty error
log on the first attempt); icons.lua re-targets every SF-Symbols literal to
`sf:` names; the workspace strip is a new event-driven komorebi adapter fed
by the enriched env (`WORKSPACES` + `FOCUSED_WORKSPACE_INDEX`, added §11.3)
with a fixed pill-slot set — killing the AeroSpace boot race the macOS tree
documents — and index-based focus clicks. Verified on screen: seven pills
bound to live workspace names, click-to-focus round trip with the highlight
following, the system-menu popup, and the battery popup's WMI-fed rows.
Divergences are cataloged in `examples/sketchybar-glass/PORTING-WIN.md`.

**Remaining to macOS parity**:
1. ~~`WM_DPICHANGED` live~~ — DONE: a real scaling round trip on the
   reference machine (200% → 175% → 200% via `SPI_SETLOGICALDPIOVERRIDE`)
   showed the bar re-rendering at exactly 40 DIP × scale (80 → 70 → 80
   physical px, pixel-sampled) with full-width layout, crisp glyphs, and an
   empty stderr across both transitions.
2. Signing — the binary is unsigned: SmartScreen warns on first run, and
   Smart App Control (enforcing on the reference machine since 2026-08-28)
   blocks fresh unsigned builds outright, so a stock Win11 install cannot
   run a CI zip at all. Azure Trusted Signing or an EV cert is the fix —
   load-bearing now, not "optional later" (§13).
3. Cutting the first `win-v0.1.0` tag (release workflow + manifests are
   ready and validated; the tag is the maintainer's call).
4. ~~Glass-theme polish~~ — RESOLVED as a deliberate restyle, not a port
   gap: the wifi/bluetooth/system-monitor popups are Win11 Fluent flyouts
   (quick-settings headers with toggle glyphs, single-line rows, plain-text
   Settings footers; Task Manager-style graphs), battery/media keep the
   shared macOS-derived layout, and the macOS hover/reveal animations are
   not carried over — the hover sites belong to the dropped menus swap and
   pill slots snap by owner preference under the flat restyle (cataloged
   in `PORTING-WIN.md`, "Deliberate restyles"). The earlier on-screen
   evidence stands: wifi popup with live netsh rows, and the media popup
   against a live Chrome GSMTC session with the marquee advancing on the
   compositor-clock pump (both opened via `--set popup.drawing=on`).

**Launcher-environment fixes** (found starting the daemon from a
`Path`-cased parent, the way Explorer and pwsh launch it — every prior
live pass had used an MSYS parent, which masked both):
1. `environmentBlock` merged the parent environment into a case-SENSITIVE
   map, so under a parent that spells the variable `Path` the exe-dir
   prepend missed it and appended a second `PATH=<exe dir>` entry; children
   resolved against that one and lost every system tool (powershell.exe,
   netsh, …). The merge now uses case-insensitive ordinal compare — which
   is also the sort order CreateProcessW documents for the block — and a
   regression test pins one merged path entry carrying both the overlay
   value and the prepend.
2. Git for Windows never puts `sh.exe` on PATH, so those same launches fell
   through to the PowerShell shell, where sh-quoted theme commands break.
   ScriptRunner now resolves sh via the `GitForWindows` registry key, and
   the child PATH prepend carries the shell's directory too — Git's sh does
   not self-prepend `/usr/bin` for `sh -c`, so without it the theme's
   tr/awk pipelines had no coreutils (§10.1).

**YTile parity** (the sibling WM, docs/YTILE-IPC.md): the ytile adapter now
carries the full komorebi-provider surface, live-verified against the real
ytiled — WORKSPACES publishes the shown workspace numbers (non-empty OR
active, the hiding the protocol doc itself recommends) with the strip
rebinding as occupancy changes; `--komorebi` workspace messages translate
onto YTile verbs (a pill click focused workspace 2 via the list-index
mapping); the reserve re-asserts on every (re)subscribe per the `ready`
contract (verified across a ytiled restart: fresh work area @0,80);
app_launched/app_terminated come from full-snapshot window diffs, primed so
the pre-existing world is never announced; ytile joins the 1 s late-attach
re-detect, always outranked by komorebi. parseState is pure and pinned by
contract tests against the protocol doc's state shape.

**Gamma correctness** (found when the theme's bar went near-black): color
bytes were sent to the GPU un-decoded, and the sRGB RTV's encode-on-store
then gamma-brightened every color ever rendered (authored `0x060607` painted
as ~`0x2b2b2f`; the original glass strip `0x1e1e2e` sampled `R96 G96 B117`).
`colorOf` now applies the exact sRGB EOTF — the reference's
`YColor.toLinear` — so the framebuffer encode round-trips to the authored
value and blending stays in linear light. Live-verified: authored
`0xfa060607` samples `R7 G7 B8`. NOTE: every pixel VALUE quoted in the
verification notes above predates this fix and is self-consistently
gamma-shifted; the geometry conclusions they supported are unaffected.

Post-replication fixes, all found chasing a user report of the cpu graph
rendering outside its pill and all live-verified: graphs now fill the
background pill height centered (reference emitGraph math), popup rows take
their height from plates/gauges/images like the reference (the cpu gauge
dashboard renders full-size dials), fixed-width items clip text to their
content box (the width-animation reveal rule; a part's zero-width slot
clipping to nothing MATCHES the reference — the mac "cpu ??%" overlay label
is invisible there too), a late komorebi attach replays state so the
workspace strip populates immediately, and the WM preference now ranks
komorebi over ytile with a live handover — on the reference machine
`komorebic start` brings up whkd, which relaunches ytiled, so both WMs
answer and "ytiled's presence is the signal" chose the idle one.

**Punch-list close-out (2026-08-28)**: the §14 komorebi gate is closed —
State + three notifications recorded from a live komorebi v0.1.41 over the
real socket subscription (`AddSubscriberSocketWithOptions` + state filter,
window title sanitized), three synthetic fixtures pin the shapes a quiet
session cannot produce (FocusChange tuple, bare-string VirtualDesktop
event, unknown-field tolerance), the provider's parsing now flows through
a pure `parseNotification` seam sharing the runtime path's core (eight
contract tests over the fixtures), and a `komorebi-canary` CI job —
independent of build, `workflow_dispatch` for quiet spells — dumps
`notification-schema`/`socket-schema` from the LATEST komorebi release and
asserts every load-bearing path (developed against the real v0.1.41
output; verified to trip on deliberate drift). One schema surprise worth
recording: `Window`'s title/exe/class/rect quintet is custom-serialized
and schemars-invisible — the canary pins `hwnd` plus an
exactly-one-property invariant, while the recorded fixtures pin the wire
quintet. The §14 glyph-clip UV-remap bullet finally got its suite (dyadic
fixtures so expected floats are exact under `==`; `clipGlyph` gained
external linkage). Theme: the bluetooth popup joined wifi in the Fluent
flyout style with its toggle reading real radio POWER over
`Windows.Devices.Radios` (PS 5.1 AsTask reflection surviving the
sh→powershell quoting layers; the timeout gates the `Result` read so a
hung WinRT call reports Unknown instead of wedging the probe), and wifi
rows carry per-network signal arcs (netsh `mode=bssid`, per-SSID max) plus
the secured lock in the reserved right-edge slot (`sf:lock`,
engine-mapped). Probe and scan pipelines live-verified through the exact
quoting layers (curly-apostrophe device name intact; open network flagged
0; signal maxima per SSID). CI green first try: 180 tests, canary
included. NOT yet re-verified on screen: the reworked popups and the
8036862 toggle glyphs — **Smart App Control began enforcing on the
reference machine** (first block observed 2026-08-28; every earlier live
pass predates the evaluation→enforce flip) and it refuses fresh unsigned
CI binaries outright, so on-screen verification waits on the signing
decision (item 2 below), which SAC upgrades from SmartScreen-nicety to
load-bearing for stock Windows 11 installs.

Deliberate divergences (never 1:1): alias items (§10.6), per-item glass
pills (§7.6), distributed-notification bindings (§9), THERMAL_STATE
(§10), single topmost z-band (§16).

---

## 16. Risk register

- **DirectWrite ink-metric parity** — the +1.5 truncation over glyph path
  bounds has no single-call DWrite equivalent; per-glyph accumulation may
  differ by a pixel on some fonts. Mitigation: golden-value suite (§14) is a
  W2 gate, not an afterthought.
- **komorebi schema drift** — no formal stability guarantee; the tagged serde
  output could change variant names. Mitigation: tolerant parsing,
  pinned fixtures + latest-release canary CI, all komorebi coupling isolated
  in one provider.
- **Stale work-area offset on crash** — offset persists in komorebi until
  config reload. Mitigation: re-zero-then-apply on every ybar start; document
  recovery; consider a `komorebic` health-check on `--exit` paths.
- **Shell compatibility** — configs written on macOS assume POSIX sh + macOS
  tools (`pmset`, `osascript`, `open`). The shell resolution (D10) keeps the
  *interpreter* compatible; the *commands* still need theme-level Windows
  variants. Themes ship with both; PORTING notes cover the rest.
- **WS_EX_NOACTIVATE / topmost quirks** — some fullscreen apps and
  DirectComposition interactions can still push topmost windows around;
  `fullscreen_show`'s triple detection path (§6) is the mitigation.
- **GSMTC session mapping** — `MEDIA_APP` values differ from `"Music"/"Spotify"`
  literals in existing scripts; ship the mapping table and document.
- **C++/Lua longjmp** — enforced by review + a debug assertion that no
  trampoline path calls raising Lua APIs (same invariant as Swift).
- **Single z-band for `topmost=window`** — behavior difference vs macOS
  floating level; documented, low impact for komorebi users (tiled windows
  never overlap a reserved strip).

---

## 17. Key references

- Swift reference implementation: this repo (`docs/ARCHITECTURE.md`, `Sources/`, `Tests/`).
- komorebi wire protocol: [komorebi-client/src/lib.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi-client/src/lib.rs), [komorebi/src/lib.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi/src/lib.rs) (`Notification`, `notify_subscribers`, `DATA_DIR`), [core/mod.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi/src/core/mod.rs) (`SocketMessage`, serde tagging), [komorebi-layouts/src/rect.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi-layouts/src/rect.rs) (`Rect` width/height semantics), [window.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi/src/window.rs) (serialized fields), [ring.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi/src/ring.rs), [komorebi-bar/src/main.rs](https://github.com/LGUG2Z/komorebi/blob/master/komorebi-bar/src/main.rs) (offset handshake, reconnect), [subscribe-socket docs](https://lgug2z.github.io/komorebi/cli/subscribe-socket.html), [LICENSE](https://github.com/LGUG2Z/komorebi/blob/master/LICENSE.md).
- Rendering/text: [CreateSwapChainForComposition](https://learn.microsoft.com/en-us/windows/win32/api/dxgi1_2/nf-dxgi1_2-idxgifactory2-createswapchainforcomposition), [Kenny Kerr — window layering with the composition engine](https://learn.microsoft.com/en-us/archive/msdn-magazine/2014/june/windows-with-c-high-performance-window-layering-using-the-windows-composition-engine), [waitable swap chains](https://learn.microsoft.com/en-us/windows/uwp/gaming/reduce-latency-with-dxgi-1-3-swap-chains), [Windows Terminal AtlasEngine](https://github.com/microsoft/terminal/pull/11623), [lhecker/dwrite-hlsl](https://github.com/lhecker/dwrite-hlsl), [IDWriteGlyphRunAnalysis::CreateAlphaTexture](https://learn.microsoft.com/en-us/windows/win32/api/dwrite/nf-dwrite-idwriteglyphrunanalysis-createalphatexture), [TranslateColorGlyphRun](https://learn.microsoft.com/en-us/windows/win32/api/dwrite_3/nf-dwrite_3-idwritefactory4-translatecolorglyphrun), [Segoe Fluent Icons table](https://learn.microsoft.com/en-us/windows/apps/design/iconography/segoe-fluent-icons-font), [fluentui-system-icons](https://github.com/microsoft/fluentui-system-icons).
- Windowing/providers: [extended window styles](https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles), [SHAppBarMessage](https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shappbarmessage), [DWM_SYSTEMBACKDROP_TYPE](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/ne-dwmapi-dwm_systembackdrop_type) (+ [wezterm precedent](https://github.com/wezterm/wezterm/pull/3528)), [GSMTC](https://learn.microsoft.com/en-us/uwp/api/windows.media.control.globalsystemmediatransportcontrolssessionmanager) (+ [Raymond Chen worked example](https://devblogs.microsoft.com/oldnewthing/20231108-00/?p=108980)), [power events](https://learn.microsoft.com/en-us/windows/win32/power/registering-for-power-events), [AF_UNIX on Windows](https://devblogs.microsoft.com/commandline/af_unix-comes-to-windows/), [per-monitor DPI](https://learn.microsoft.com/en-us/windows/win32/hidpi/high-dpi-desktop-application-development-on-windows), [DISPLAYCONFIG_TARGET_DEVICE_NAME](https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-displayconfig_target_device_name).
- Third-party bar precedent: [yasb komorebi integration](https://deepwiki.com/amnweb/yasb/7.3-komorebi-integration), [zebar work-area issue](https://github.com/glzr-io/zebar/issues/50), [komorebi named-pipe subscription example](https://gist.github.com/peddamat/ac8f78a375d003d69669d75a012a6c46).
