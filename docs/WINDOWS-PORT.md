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
  and the wallpaper backdrop brush, and simplifies composition assumptions).
  Win10 may work degraded; not tested.
- The `alias` component (macOS menu-bar-extra capture). Grammar accepted,
  creation returns a clear error (§10.6).
- Feature parity with macOS-26 Liquid Glass. Bar `glass=on` maps to DWM
  Acrylic and item `glass=on` to a Mica backdrop (§7.6); neither refracts.
- Wayland/Linux, other WMs (GlazeWM etc. can integrate the AeroSpace way —
  config-side — but get no native provider in v1). YTile, the sibling WM, is the
  one exception: it has an in-tree `YTileProvider` (named-pipe NDJSON; §15).

---

## 2. Decision record

| # | Decision | Choice | Rationale |
|---|---|---|---|
| D1 | Language | **C++20**, MSVC, CMake + vcpkg | Native fit for COM/D3D; AtlasEngine/Terminal patterns lift near-verbatim; owner preference |
| D2 | Repo | **Orphan branch `windows`** in the YBar repo, worktree checkout | One repo/issue tracker; own root history so the two lines never merge; per-branch CI; themes+examples copied in, contract doc shared |
| D3 | Renderer | **D3D11** + DXGI flip-model composition swap chain + **Windows.UI.Composition** (bar and popups; the Mica layers, §7.6); HLSL compiled at runtime via `D3DCompile` | Only clean per-pixel premultiplied-alpha path (`WS_EX_NOREDIRECTIONBITMAP`); preserves "no shader toolchain at build time" |
| D4 | Text | **DirectWrite** full stack; **grayscale AA forced** | ClearType subpixel breaks the R8 coverage atlas and transparent composition |
| D5 | WinRT/COM | **C++/WinRT** (GSMTC media; the compositor, §7.1/§7.6) + **WRL `ComPtr`** (COM lifetime; `wil` is listed in vcpkg.json but unused) | Header-only, ships with the Windows SDK |
| D6 | Lua | Vendored **Lua 5.4 built as C**, raw C-API bridge mirroring `LuaRuntime.swift` incl. the non-raising-trampoline invariant | `lua_error` longjmp through C++ frames skips destructors — same UB class the Swift bridge engineered around |
| D7 | IPC | **AF_UNIX** (Winsock, `afunix.h`), socket at `%LOCALAPPDATA%\ybar\` | Wire-format parity with macOS; komorebi proves AF_UNIX in production and uses the same location convention |
| D8 | komorebi | **Native `KomorebiProvider`** speaking the socket protocol directly (no Rust crate) | C++ can't link `komorebi-client`; protocol is simple (one JSON per connection, §11) |
| D9 | Space reservation | komorebi **`MonitorWorkAreaOffset`** handshake by default; **SHAppBarMessage appbar** as opt-in fallback for non-komorebi users | komorebi-bar precedent; double reservation (appbar + offset) must be impossible |
| D10 | Scripts | `sh -c` when `sh.exe` resolves (PATH, else Git for Windows via its `GitForWindows` registry `InstallPath`), else PowerShell `-NoProfile`; `YBAR_SHELL` override (POSIX sh / PowerShell / cmd, classified by basename) | Every shipped config writes POSIX sh; komorebi users almost universally have Git installed |
| D11 | Icons | Keep `sf:`/`sf.` grammar; resolver maps names via a compiled-in table (`render/icon_map.cpp`) to **Segoe Fluent Icons**, falling back to **Segoe MDL2 Assets** then an installed **FluentSystemIcons-Resizable** face (nothing is bundled) | SF Symbols are Apple-proprietary; grammar is the contract, artwork is swappable |
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

Windows-specific **added** verbs (ybar-win extensions, absent from the
reference): `--komorebi <socket-message-json>` (§11.5), `--tray <name>
invoke|close` (§10.6), `--volume <0-100> [app]` (§10, Audio row), and
`--window <hwnd> close|kill` — `close` posts `WM_CLOSE` (never sent, so a
hung app cannot stall the bar), `kill` is `TerminateProcess`; the `hwnd`
comes from `--query windows` (§3.6). Any other domain still replies
`[!] unknown domain: --<name>`.

### 3.3 Property namespace (`PropertySetter.swift`, `BarPropertySetter.swift`)

The complete dotted-path grammar, verbatim — including every
accepted-and-ignored sketchybar-compat key (`padding_top`, `space`,
`associated_space`, `mach_helper`, `font.features`, `popup.topmost`, …), the
color channel addressing (`.alpha/.red/.green/.blue/.hex`), `0xAARRGGBB`
colors, bool grammar (`on/off/true/false/yes/no/1/0` + `toggle` on bool
leaves), `width=dynamic` (-1 sentinel with measured-width animation seeding),
auto-enable of `background.drawing` on color set, lazy `gauge.*`/`image.*`
component attachment, and the exact `[!]`/`[?]` error string formats (one
known slip to close in code, not in this contract: the port replies
`[!] invalid boolean:` for `image.drawing` and `[!] invalid image.drawing:`
for `background.image.drawing` — the reverse of the reference).

Windows-specific accepted no-ops: `notch_width`, `notch_offset`,
`notch_display_height` (no notched hardware — number-validated, stored and
animated like every other bar float leaf and echoed by `--query bar`, but
layout always runs with a notch width of 0) and `font_smoothing` (accepts any
value; never read — a no-op in the reference too). `wifi_ssid_prompt` is
**not** a no-op: it is bool-validated (no `toggle`) and `on` opens
`ms-settings:privacy-location`, the Windows stand-in for the reference's Core
Location request (§10, Network row, for the 24H2 caveat).

Windows-specific **added** keys (deliberate divergences; each absent from the
reference namespace, listed again in §15's divergence roll-up):

- `slider.interactive` (bool, default `on`): `off` makes a slider a
  **read-only meter** — the press/drag path is skipped entirely, while
  property sets still apply and rendering is unchanged. Without it, any item
  carrying `item.slider` gets its percentage **overwritten from the pointer
  x on every mouse-down** (bar and popup paths both), so a battery-style
  fill meter showed a fabricated value on click and scrubbed on drag.
  Serialized in `--query` as `"interactive": on|off`.
- `image.desaturate` (bool, default `off`): renders a colour image greyscale
  via a Rec. 709 luma conversion in the shader (§7.3). The glyph pipeline
  multiplies colour-atlas samples by the instance colour's **alpha only**,
  discarding its RGB, so without this flag a colour icon cannot be dimmed to
  grey from Lua at all.
- `image.y_offset` (float, default 0, positive-up like a text part's):
  images centre on the em box while text ink sits below that centre, and a
  theme cannot close the gap with the text's own `y_offset` — moving the
  text changes the row height, which re-centres the image and chases the
  gap. The tray rows drop their icon onto the label's optical centre with
  `-4`.
- bar `reserve` (`auto|komorebi|appbar|off`, default `auto`): which mechanism
  reserves the bar's strip — the tiling WM's work-area offset (komorebi's
  `MonitorWorkAreaOffset`, or YTile's `reserve` verb when ytiled answers
  instead), the shell's `SHAppBarMessage`, or nothing; `auto` resolves to
  the WM path when one is detected, else off, and `komorebi` behaves the
  same (§6.1). `off`/`appbar` also suppress the WM subscription entirely.
  Any other value replies `[!] invalid reserve: <value>`. Absent from the
  reference `BarPropertySetter`, where it falls to the `[?] unknown bar
  property` arm.

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
`update_mask` values. The forced-query `--trigger` interception set carries
the reference's eight — `volume_change, power_source_change, battery_change,
wifi_change, front_app_switched, display_change, system_stats, media_change`
— plus the Windows workspace re-queries `komorebi_workspace_change` and
`ytile_workspace_change` (§11.3).

Two custom events are registered by the daemon itself, not the config, when
a tiling WM is detected and `reserve` is not `off`/`appbar` (§6.1):
`komorebi_workspace_change` (fired by both the komorebi and the YTile path,
so themes work unchanged) and `ytile_workspace_change` (YTile only). They are
re-registered on every reload before the config runs, so a config's own
`--add event` bits follow them. Both carry `FOCUSED_WORKSPACE`,
`PREV_WORKSPACE`, `FOCUSED_MONITOR_INDEX`, `WORKSPACES`,
`FOCUSED_WORKSPACE_INDEX`, and the built-in `space_change` fires alongside
them with the same env (§11.3; YTile parity paragraph in §15).

### 3.5 Script environment

`NAME`, `SENDER` (event | `routine` | `forced`), `INFO`, `BUTTON`
(`left|right|other`), `MODIFIER` (`shift|ctrl|alt|cmd|none`, priority
shift>ctrl>alt>cmd — **`cmd` maps to the Windows key**), `SCROLL_DELTA`,
`PERCENTAGE`, `CONFIG_DIR`, `BAR_NAME`, plus the per-event extras
(`CPU_USAGE/CPU_FRACTION/MEMORY_*/DISK_*_GB/THERMAL_STATE`, `MEDIA_*`,
`FOCUSED_WORKSPACE/PREV_WORKSPACE/FOCUSED_MONITOR_INDEX/WORKSPACES/FOCUSED_WORKSPACE_INDEX`).
`NAME/SENDER/INFO` are applied last and cannot be spoofed by `--trigger`
extras. INFO payload shapes per event are identical (e.g. `system_stats` =
`{"cpu": N, "memory": N}` with the space after the colon; `mouse.clicked`
INFO = compact `{"button":"…","modifier":"…"}`).
`THERMAL_STATE` is always `nominal` on Windows (no public equivalent) — the
variable stays so scripts don't break.

### 3.6 `--query` JSON

All shapes byte-compatible modulo JSON number formatting: `bar`, `defaults`,
`events` (`{"name": {"bit": n, "notification": "(null)"}}`), `displays`
(keys `arrangement-id`, `frame{x,y,w,h}`, `scale`, `main`, `DirectDisplayID` —
key names verbatim; on Windows `DirectDisplayID` carries a stable numeric id
derived from an FNV-1a hash of the monitor device name
(`MONITORINFOEX.szDevice`, e.g. `\\.\DISPLAY1`), documented as platform-defined),
and per-item (geometry/icon/label/scripting/bounding_rects/…). Pretty-printed,
sorted keys, colors `0x%08x` lowercase. **Coordinate-space note:** `frame` and
`bounding_rects` values are y-down device-independent points on Windows (the
native convention); the macOS build reports AppKit y-up global points for
`frame`. Document this — do not convert.

Windows extension targets (all arrays, matched **before** item lookup so
they reach Lua through the existing query trampoline unchanged): `--query
windows` returns the running-app list, `--query tray` the notification-area
registrations as `{name, hidden, icon}` rows (§10.6), and `--query audio`
the default endpoint's audio-session groups as
`{id, name, path, volume, muted, active}` rows (§10, Audio row).

### 3.7 Lua API (`LuaRuntime.swift` + prelude + sbar shim)

The whole surface: `ybar.bar/default/set/subscribe/delay/update/query_table/
trigger/push/exec/add_event/query/remove/animate/add/item`, item handles
(`h:set/subscribe/push/query`, `h.name`), nested-table flattening, valstr
coercion (booleans → `on`/`off`, integral floats → integer strings), the
18-trampoline raw bridge (the reference's 16 plus the two Windows additions
below), registry-ref subscriptions keyed per item per event,
generation-guarded `exec`/`delay` completions, SENDER=forced → `routine`
handler fallback, Lua-first-then-shell dispatch, and the pure-Lua `sketchybar`
compat shim shipped verbatim except for one Windows-only addition,
`sbar.tray(name, action)`, which forwards to `ybar.tray`. The Lua prelude is
plain Lua source and ships **byte-identical** apart from the two inserted
lines that expose `ybar.tray`/`ybar.volume` (below). Bridge invariants
preserved: no `luaL_check*`/`luaL_error` in trampolines (longjmp/destructor
UB), key-copy before stringify in table walks, `lua_State` generation counter.

Two deliberate Windows **additions** ride the raw bridge, both replacing a
shell round trip into the daemon the config already runs inside (measured
35–54 ms of `cmd.exe` plus 41–44 ms of CLI socket per call):
`ybar.tray(name, action)` (no macOS counterpart — there is no notification
area to act on) routes the §10.6 tray verbs through the daemon's own
token-dispatch path in-process, and also retires the shell-metacharacter
guard an app-controlled registry tooltip once forced. And `ybar.volume(pct[, app])`
routes `--volume` (§10, Audio row): macOS themes shell
`osascript -e 'set volume …'`, while this daemon already holds the
`IAudioEndpointVolume` — the previous theme workaround synthesized volume-key
ticks through PowerShell SendKeys, one shell spawn per adjustment at 2 %
quantization. The optional app id (`--query audio`'s `id` field) routes the
set to that app's audio-session group instead of the master endpoint —
per-app volume has no macOS API at all, so this half of the verb has no
reference analog either.

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
image → icon → graph/slider/gauge → label, the image trailing the label
instead when `image.align=r`; all quads → all triangles → all glyphs), pixel
snapping (origin and size rounded independently), hard offset shadows (see
the shadow note below), `background.clip` holes (max 32 here; the reference's
16, raised because glass pills spend from the same budget, §7.6), graph
right-to-left on the leftward-flowing cursors (`right` and `q`), gauge 270°
dial with label centered inside contributing zero width. Deliberate graph
deviations: the reference centers a zero sample's stroke ON the box bottom
(half the line hangs outside — under a bordered plate it overpaints the
border and reads as a baseline under the stadium, user-reported); the port
clamps line centers to [minY+half, maxY−half] and insets the graph box by
the plate's border width, so stroke and fill stay inside the frame. And a
graph item's own plate (and its shadow) squares its BOTTOM corners — only
the top two keep the theme's corner_radius — so the flush baseline meets a
90° frame instead of being cut by the bottom rounding (chart-frame look, per
the maintainer).

---

## 4. Branch layout

Root of the `windows` branch (`git worktree add ..\ybar-win windows`):

```
ybar-win/
  CMakeLists.txt            — C++20, MSVC, vcpkg manifest (nlohmann-json, wil, catch2)
  CMakePresets.json         — Ninja + vcpkg toolchain, x64-windows-static;
                              `default` (Debug, tests) and `release` presets
  vcpkg.json                — manifest: catch2, nlohmann-json, wil
  .github/workflows/        — ci.yml (build, ctest, signed artifact, komorebi
                              schema canary); release.yml (`win-v*` tags →
                              signed zip)
  src/
    main.cpp                — argv → client | daemon (mirrors ybar/main.swift)
    app/                    — daemon lifecycle, message loop, config exec, hotload
    ipc/                    — wire format, server (accept thread), client, parser, handler
    model/                  — Item, Style, Components, Layout, PropertySetter, Serialize
    events/                 — EventBus: 20 built-in names in contract order +
                              custom events, u64 bitmask
    anim/                   — curves, scheduler (compositor-clock driven)
    render/                 — D3D11 device/swapchains, SceneBuilder, GlyphAtlas,
                              FontCache (DirectWrite), Instances (shared GPU ABI)
    win/                    — BarSurface and PopupSurface (HWND +
                              Windows.UI.Composition via CompositionHost: swap
                              chain over a Mica layer), DisplayManager,
                              MouseRouter, backdrop, appbar
    providers/              — audio (+ audio_sessions mixer), network, media (GSMTC),
                              app_info, app_lifecycle, window_list, tray_icons, and the
                              komorebi + ytile WM adapters (subscription + work-area +
                              commands; komorebi outranks). Power, stats and the
                              front-app hook are polled inline by app/daemon.cpp
    lua/                    — Lua 5.4.8 vendored (C) under vendor/; runtime.cpp bridge,
                              prelude embedded as a string constant (the reference
                              prelude + Windows-only ybar.tray/ybar.volume bindings)
  shaders/ybar.hlsl         — shipped loose beside the exe, D3DCompile at startup
  themes/                   — placeholder (README only); the shipped themes live under
                              examples/. `ybar theme list` searches examples/ + themes/
                              beside the exe, then ~/.config/ybar/themes
  examples/
    komorebi-whkd/          — replaces yabai-skhd: pairing guide + whkd bindings
    catppuccin-komorebi/    — shipped flagship theme (declarative ybarrc.jsonc)
    sketchybar-glass/       — port of the macOS flagship Lua theme + PORTING-WIN.md
  tests/                    — Catch2 port of the Swift contract tests
  lua/sketchybar.lua        — SbarLua compat shim (`sbar` API over the embedded runtime);
                              byte-identical to examples/sketchybar-glass/sketchybar.lua
  packaging/                — winget (NineFiveB.ybar-win.*.yaml) + scoop (ybar-win.json)
                              manifests, release how-to
  scripts/install.ps1       — the README install one-liner
  docs/WINDOWS-PORT.md      — this file (copy)
```

Binary name stays `ybar.exe`. **Instance name = basename of argv[0] with the
`.exe` extension stripped** — the Swift code's `lastPathComponent` would
otherwise poison the socket path (`ybar.exe_user.sock`) and config discovery
(`~/.config/ybar.exe/`). Renaming the binary (`ybar2.exe`) still yields an
independent instance.

---

## 5. Process model & lifecycle

- `main.cpp`: empty argv or a leading `-c/--config` → daemon; `-h/--help` and
  `-v/--version` print locally; `theme …`/`autostart …` are handled in-process
  (only `theme use` sends a `--reload <entry>` over the socket). Anything else
  → thin client (strip a leading `-m/--message`, fold `AEROSPACE_*`/`YABAI_*`/
  `KOMOREBI_*` env on `--trigger`, serialize argv → socket → print reply; `[!]`
  replies go to stderr, exit 1).
- Daemon boot order (mirrors `Daemon.swift`): `CoInitializeEx` (STA) → create
  hidden message-only window → bind socket (instance lock, before any shared
  state is touched) → renderer + per-display bar windows (headless if the GPU
  stack fails) → wire EventBus + mouse routing → attach **YTile, then komorebi
  if detected** (komorebi outranks; both gated by `reserve`) → always-on
  providers (power notifications, front-app hook, low-level mouse hook) → lazy
  providers (audio, network, media, stats, app lifecycle) armed on first
  subscription (audio/network/media also by an explicit `--trigger`) → build
  CommandHandler + Lua runtime → start IPC accept thread → start 1 s routine
  timer (`SetTimer`) → execute config → first frame → enter the message loop
  (a `PeekMessage` drain followed by `MsgWaitForMultipleObjectsEx` on the
  frame-due event, not a plain `GetMessage` loop).
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
- Config discovery, reference order plus two ybar-win additions, with `<name>`
  = instance name: `-c <path>` (with `~` → `%USERPROFILE%` expansion; a
  missing file runs configless rather than falling through) → `current-theme`
  (default `ybar` instance only, resolved to the theme's entry file; a stale
  name falls through; `ybar theme reset` clears it) → `%XDG_CONFIG_HOME%\<name>\`
  → `~/.config/<name>/` → `~/.<name>rc(.lua)`; per directory `<name>rc.lua` →
  `<name>rc` → `<name>rc.jsonc` → `<name>.jsonc` (JSONC entries are first-class
  on ybar-win; the home dot-file tier is `.lua`/bare only). `~/.config` works
  fine on Windows and keeps theme docs identical.
- Hotload: `ReadDirectoryChangesW` on the config **directory**
  (`FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NAME`), which sees in-place writes
  *and* atomic rename-saves — the dual vnode watch from macOS collapses to one
  watcher. Keep the 0.5 s trailing debounce and the 1.0 s post-reload
  suppression window verbatim (config runs write into the watched directory
  and would loop; the "drops saves within 1 s of a reload" tradeoff is
  documented behavior, not a bug).
- `--reload [path]`: a path that exists (tilde-expanded) becomes the sticky
  config source for this and every later reload; a missing path is refused
  and the current config re-runs (reference behavior). After `--reload
  <path>` or `ybar theme use`, the hotload watcher re-points at the new
  config's directory.
- Shutdown (`--exit`, `WM_ENDSESSION`): `--exit` replies first and quits from a
  150 ms timer that stops the komorebi/YTile subscription and zeroes its
  work-area offset (§11.4; `WM_ENDSESSION` zeroes it directly); then unhook,
  stop IPC, destroy windows, exit 0.
- Diagnostics: `YBAR_DEBUG` (any value) traces daemon bring-up, surface/DPI
  geometry, per-frame render stats and the measured animation frame rate to
  stderr. (The `YBAR_DCOMP_SCALE` override went with the move to
  Windows.UI.Composition; §7.1 records why no scale is needed.)

### 5.1 IPC endpoint

`%LOCALAPPDATA%\ybar\<instance>_<user>.sock` (AF_UNIX, `SOCK_STREAM`;
`sun_path` limit 108 bytes — if exceeded, fall back to
`%TEMP%\<instance>_<user>.sock`, or `C:\Windows\Temp` when `%TEMP%` is unset —
silently, nothing is logged). Access control: the socket file gets an
explicit DACL restricted to the current user SID (the macOS `chmod 0600`
is security-relevant — this is unauthenticated command execution). Delete
stale file before bind; `closesocket` not `_close`; no `SIGPIPE` on Windows
(`send` returns `WSAECONNRESET`).

**Cross-component coupling**: the theme switcher must use the same path. The
POSIX `scripts/ybar-theme` became the built-in `ybar theme
list|current|use <name>|reset` subcommand (no `.ps1`; `install <git-url>` is
not ported, `reset` is new). `use` records `current-theme` and sends
`--reload <entry>` over the same socket, falling back to "recorded; start ybar
to apply" when no daemon answers (the next start picks it up through config
discovery, §5). The `~/.config/ybar/themes/` + `current-theme` state file
layout is preserved; shipped themes are found in `examples/` or `themes/`
beside the exe (or `../examples` from a build tree).

---

## 6. Windowing

Per included monitor, `BarSurface` creates:

```
HWND  WS_POPUP | (borderless)
      WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP
      [+ WS_EX_TOPMOST per topmost setting]
 └─ Windows.UI.Composition DesktopWindowTarget (win/composition_host.cpp)
    ├─ backdrop layer: one SpriteVisual per glass pill, wallpaper backdrop
    │  brush, rounded-rectangle geometric clip (§7.6)
    └─ content: SpriteVisual over the DXGI composition swap chain
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
- `sticky=on` (default): follow the active virtual desktop via the documented
  `IVirtualDesktopManager` (`MoveWindowToDesktop`, re-driven from the daemon's
  1 s tick because desktop switches raise no window message; the current
  desktop's GUID is read from Explorer's `CurrentVirtualDesktop` registry
  value, foreground window as fallback). True pinning lives behind the
  undocumented, build-fragile `IVirtualDesktopPinnedApps` and is not used;
  with komorebi, workspaces are komorebi's own concept and a topmost tool
  window is visible across them anyway — a missing manager degrades to a
  one-time warning. `sticky=off` = no following.
- DPI: `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`
  at daemon start (no manifest is embedded); scale = `GetDpiForWindow()/96`;
  handle `WM_DPICHANGED` like `viewDidChangeBackingProperties` (resize buffers,
  switch glyph-atlas scale). One `GlyphAtlas` per distinct scale, as on macOS.
  Popup scenes build at the **host surface's** scale: a fresh window's DPI
  comes from the monitor at its **creation position** — a popup created at
  default coordinates reports the primary monitor's DPI and only corrects via
  `WM_DPICHANGED` after being moved (same operational rule as macOS,
  different mechanism; creating popups directly at their target coordinates
  also works).
- Displays: enumerate `EnumDisplayMonitors`; the public contract stays the
  **1-based arrangement index** (primary = 1, then enumeration order);
  internally there is no re-matching across `WM_DISPLAYCHANGE`: every
  surface (and glyph atlas) is torn down and the set rebuilt from a fresh
  enumeration, debounced 500 ms (the sledgehammer, kept), and re-tried from
  the 1 s tick with 1→60 s backoff while surfaces are missing
  (`recoverMissingSurfaces`). `display` accepts `all`, `main`, or a
  comma-separated list of those indices (`[!] invalid display list`
  otherwise); there is no `active` value at bar level, and the item-level
  `display=` association (`active` or an index list) is stored but not
  consulted by layout.
- `fullscreen_show`: detection ANDs two signals —
  `SHQueryUserNotificationState` in {`QUNS_BUSY`,
  `QUNS_RUNNING_D3D_FULL_SCREEN`, `QUNS_PRESENTATION_MODE`} for *whether* a
  real full-screen app owns the session, and foreground-window-rect ==
  monitor-rect for *which* monitor. Neither alone is right: the shell state
  has no per-monitor notion, and geometry alone cannot tell a full-screen app
  from an ordinary borderless window that merely spans the display — hiding
  the bar under a "Windowed (Fullscreen)" game and a maximized borderless
  editor was user-reported. Re-evaluated on the 1 s tick, on
  `ABN_FULLSCREENAPP`, on every foreground-window change
  (`EVENT_SYSTEM_FOREGROUND` win-event hook), after a surface rebuild, and
  on every workspace switch (a switch changes the foreground window).
  **Policy per monitor**: `fullscreen_show=on` elevates that surface to
  topmost *over* the fullscreen window (macOS parity); `fullscreen_show=off`
  (the default) **auto-hides** the surface while fullscreen is detected on
  its monitor and shows it again otherwise — the Win11-taskbar convention,
  and the analog of the macOS bar not drawing over a fullscreen Space.
  Auto-hide ORs with the user's `hidden=` toggle and keeps the appbar
  reservation (no window reflow when toggling). Switching to a workspace
  without the fullscreen window restores the bar because its foreground no
  longer covers the monitor. **Known limitation** (pre-existing in the
  detector, shared by the elevation path): detection keys off the single
  *global* foreground window, so a fullscreen app on a monitor you are not
  focused on is not detected — that monitor's bar stays put until its window
  is focused. A per-monitor top-window scan would lift this but risks false
  positives on background borderless-maximized windows, so it is deferred.
- `hidden`, `shadow` (DWM shadow toggle), `margin/y_offset/height/position`
  math identical (all y-down native — the AppKit y-up conversions are simply
  deleted).
- Mouse: WndProc `WM_LBUTTONDOWN/UP`, `WM_RBUTTONUP`, `WM_MBUTTONUP`,
  `WM_MOUSEMOVE` + `TrackMouseEvent(TME_LEAVE)`, `WM_MOUSEWHEEL`
  (`GET_WHEEL_DELTA_WPARAM/120`, sign preserved). A `WM_MOUSELEAVE` is
  believed only when `GetCursorPos` is outside the window rect, and otherwise
  re-arms tracking: the z-order and desktop-following upkeep on the 1 s tick
  moves the window under a stationary pointer, and Windows posts a leave the
  pointer never performed. Untested for a year because nothing hovered — with
  targeted `mouse.entered`/`mouse.exited` driving a highlight it made every
  hovered item blink once a second. Click fires on button-up.
  `WM_LBUTTONDOWN` takes `SetCapture` (bar and popup WndProcs alike) so a
  slider drag keeps receiving Move/Up after the pointer leaves the thin
  window; a stolen capture (`WM_CAPTURECHANGED` that is not our own release)
  ends the drag with a synthetic Up at the cursor position. Modifiers via
  `GetKeyState` mapped `shift>ctrl>alt>cmd(Win)` for surface events; the
  global `modifier_change` path reads `GetAsyncKeyState`, because
  `GetKeyState` is stale on a message-only window that never has focus.
  Global popup-auto-close + `mouse.exited.global`/`modifier_change` need
  `SetWindowsHookEx(WH_MOUSE_LL / WH_KEYBOARD_LL)` — no permission prompts on
  Windows. UIPI caveat: a non-elevated process's low-level hooks do not
  observe input delivered to elevated windows, so popup auto-close and
  modifier tracking degrade while an elevated app has focus — acceptable; do
  not pursue uiAccess. Warped-cursor defenses: containment is the
  `WindowFromPoint` class test (`pointOverYBarWindow`) run on every
  `WH_MOUSE_LL` move once the global events are subscribed, with no
  debounce; a global exit is vetoed while a slider drag is live and the
  release re-verifies containment via `GetCursorPos`; a surface rebuild
  forces an exit because a destroyed window never sends `WM_MOUSELEAVE`.
- Popups: same lifecycle invariants — a popup panel counts as live only after
  its scene rendered; anchor math (host frame → screen coords, l/c/r align,
  below-bar for top position) is pure arithmetic over y-down coords, then
  clamped into the anchor's monitor: a 7 pt edge inset (right clamp first,
  then left, so an over-wide panel overflows rightwards rather than
  off-screen) and a vertical flip to the other side of the bar, not a slide,
  when the panel would run off the bottom or top.

### 6.1 Space reservation (replaces "windows avoid the menu bar")

New bar property (Windows extension; the macOS build currently rejects it
with `[?] unknown bar property: reserve`):

```
--bar reserve=auto|komorebi|appbar|off   (default: auto — komorebi when detected,
                                          else YTile when detected, else no
                                          reservation; `komorebi` behaves like `auto`)
```

- `komorebi` (and `auto`): send `MonitorWorkAreaOffset` to every komorebi
  monitor — one offset, `(height + y_offset) × the first surface's scale`
  (zero while `hidden=on`); `display=` exclusions are not applied (§11.4).
  With komorebi absent the same mode drives YTile's `reserve` command
  instead.
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
`FLIP_SEQUENTIAL`, BufferCount 3, `DXGI_SCALING_STRETCH`). Every surface
binds it with Windows.UI.Composition (`CreateDispatcherQueueController` on
the UI thread → `Compositor` → `ICompositorDesktopInterop::CreateDesktopWindowTarget`
→ `ICompositorInterop::CreateCompositionSurfaceForSwapChain` → surface brush
on a `SpriteVisual`; `win/composition_host.cpp`), because the Mica layers
(§7.6) need a backdrop brush that only that API has; the popup open/close
fade is a linear `ScalarKeyFrameAnimation` on the tree's root opacity
(`CompositionHost::rampOpacity`), where it used to be a DirectComposition
effect group. DirectComposition survives only as the animation pump's
`DCompositionWaitForCompositorClock` (§7.2). This is the canonical
transparent GPU-window recipe (Kenny Kerr, MSDN 2014; Qt uses the same),
with the WinRT compositor in place of the DComp device. The compositor,
its dispatcher queue and the wallpaper brush are created on first use and
deliberately never destroyed: a WinRT object in static storage is released
after COM has been torn down at exit, which is a crash for no benefit.

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

**Composition scaling (corrected after a live miss)**: a composition target —
DirectComposition and Windows.UI.Composition alike — composes in the WINDOW's
coordinate space, which is physical pixels for a PerMonitorV2 process — so a
physical-pixel swap chain maps 1:1 with **no visual transform**, and the
backdrop visuals take the display list's device-px rects verbatim (verified at
200 %: they land on their pills). Do NOT add a `96/windowDpi` counter-scale:
it halves the scene, producing a full-width window that paints only its left
half. That failure is easy to misread, because glyphs rasterized at 2× and
displayed at 0.5× still *look* correctly sized — only the geometry betrays it.
Verify by sampling painted pixels at the far edge of the monitor, never by
eyeballing text size.

### 7.2 Damage model & pacing (behavior contract)

DWM is a retained compositor: **no render loop at rest** — `setNeedsRender()`
coalesces model changes to one full-scene re-encode posted to the UI thread;
render + `Present(1,0)` only then. No partial damage — damage gates *whether*
a frame renders, never what is drawn. While animations or a marquee are
active, pace frames with `DCompositionWaitForCompositorClock` on a dedicated
pump thread (it ticks at the display's real refresh rate; the thread drops to
a ~16 ms wait if the clock is unavailable, and a 16 ms `WM_TIMER` stands in
only when the pump cannot start), on-demand start/stop exactly like the
CADisplayLink (the scheduler's `continuousDemand`/`reattach` discipline
carries over). Animation durations remain frames/60 seconds at any refresh
rate. A failed present → 1 s retry (`kRenderRetryTimer`); missing bar surfaces
are rebuilt from the 1 s tick with exponential back-off (1 s → 60 s). The D3D11
device itself is created once at boot and is never recreated.
Acceptance: PresentMon / Task Manager GPU shows ~0% while the bar is static.

### 7.3 Pipelines & shader

Three PSOs (quad, shape, glyph) sharing one blend state (`SrcBlend=ONE`,
`DestBlend=INV_SRC_ALPHA`, both channels), cull mode **NONE** (the unit-quad
strip winding is not guaranteed CCW), no MSAA. `shaders/ybar.hlsl` ships as a
loose file beside the exe (`<exe dir>\shaders\ybar.hlsl`, read from disk) and
compiles at startup with `D3DCompile` (vs_5_0/ps_5_0). Ship
`d3dcompiler_47.dll` **app-local** next to `ybar.exe` (redistributable under
the Windows SDK license, ~4 MB): the System32 copy exists on all Win 10/11
machines but is only documented as supported for UWP apps — app-local is the
supported path for desktop apps and preserves the no-build-time-toolchain
property.

**Shadows — two additive Windows extensions (§3.9).** The reference draws a
shadow as a hard offset COPY of the plate with no blur, and only for non-bracket
items (`SceneBuilder.swift`, bracket pass emits a background quad and nothing
else). Both still hold by default here, because both extensions are opt-in and
both default to off:

- `background.shadow.blur` (points, default **0**). Above 0 the shadow quad is
  grown by the blur on every side, the true shape half-size is carried in
  `fill2.xy`, the radius in `gradientDir.x`, and `kQuadFlagShadow` (bit 4)
  selects a squared smoothstep ramp instead of the analytic AA edge. All three
  of those fields are unused on a shadow quad, so **`QuadInstance` stays 112
  bytes and byte-identical with Instances.swift** — a macOS build that never
  sets the flag is unaffected. A LIGHT shadow colour at distance 0 with a blur
  is a GLOW; that is the only bloom this pipeline has, and the workspace focus
  halo in sketchybar-glass uses it.
- Brackets emit shadows too, via the shared `pushShadow`. The reference does
  not. This matters because in a bracket-based theme every pill IS a bracket,
  so shadows and glows would otherwise be unreachable on exactly the elements
  that want them. Invisible unless `background.shadow.drawing` is set, which
  defaults off.

**Item-level `glass` paints the bevel rim in the shader; the material under
it is the window layer's job (§7.6).** The branch
builds a real `float3` surface normal by treating the pill as a slab with a
quarter-round bevel — the normal of a quarter circle at depth `t` is
`(outward * sqrt(1 - t²), t)` — and shades it Blinn-Phong. It previously used
`normalize(float2(ddx(d), ddy(d)))` as a "normal", which is a unit 2D screen
direction with no height term and cannot light a surface. Two constraints are
easy to get wrong and are load-bearing: the coefficients are LINEAR light
against an sRGB target, so on a near-black theme (26/255 ≈ linear 0.010) the
usable range is only about (−0.004, +0.014) — and both the response and those bounds are scaled by the fill's luminance
(gain 1 at that reference fill, capped at 8), because the same absolute numbers on a mid-grey fill are a ±2
ripple and `glass = true` silently did nothing on the focused-workspace pill until they were; and the key light's azimuth swings
toward the pointer at FIXED elevation, because leaning the whole vector also
drops `L.z`, which is the flat-face reference the bevel is measured against, and
the effect then cancels itself to 1–2 levels out of 255.

`Uniforms` is **32 bytes here, not the reference's 16**: it carries the pointer
position (device px on the surface being drawn, negative = pointer away) for
that key light. It is a per-frame constant buffer, not the shared per-item
instance ABI. The daemon gates the pointer path three ways — only when a glass
quad is actually on screen, only past 3pt of travel, and never faster than
60 Hz — so a flat theme pays nothing and zero-work-at-rest is preserved.

The MSL→HLSL translation is mechanical — validated against the shader source:
`[[vertex_id]]/[[instance_id]]` → `SV_VertexID/SV_InstanceID`; device pointer
vertex-pulling → `StructuredBuffer<QuadInstance>` in `t0`; `Uniforms` →
`cbuffer b1`; holes → `StructuredBuffer<Hole>` (keep the explicit `float3`
pad = 32-byte stride); `constexpr sampler` → a `SamplerState` at `s0` fed by
a runtime-created `ID3D11SamplerState` (LINEAR, CLAMP); `fwidth/dfdx/dfdy` →
`fwidth/ddx/ddy`; `mix` → `lerp`; `atan2` argument order identical;
`SV_Position.xy` in the pixel shader gives top-left pixel coords exactly like
`[[position]]` (the hole-cutout math depends on this and ports unchanged);
Metal and D3D share NDC conventions so `to_clip` is untouched. The GPU
instance ABI (QuadInstance 112 B / GlyphInstance 64 B / ShapeVertex 32 B /
Hole 32 B, flag bits, binding slots t0/b1/t0+t1 textures, holes at PS `t2`)
is preserved with static asserts. `cornerExponent` stays transmitted-but-unused,
as on macOS. One Windows-added flag bit extends the ABI: `kGlyphFlagDesaturate`
(`1u << 1`; `kGlyphFlagGrey` in the HLSL) applies a Rec. 709 luma conversion
to colour-atlas samples — valid directly on premultiplied colour — backing
`image.desaturate` (§3.3). The painted glass rim (`flagGlass`) ships with
its exact constants and stays ON over the Mica backdrop — the opposite of the
reference's `nativeGlassBackdrops` gate, which drops the rim over macOS-26
Liquid Glass because that material refracts and carries its own edge. Mica is
flat, so the rim is what gives the pill one.

### 7.4 Text (DirectWrite)

Model on Windows Terminal AtlasEngine + `lhecker/dwrite-hlsl`:

- **Shaping**: `IDWriteTextLayout` + a custom `IDWriteTextRenderer` run
  collector (`font_cache.cpp`) — the layout engine owns shaping AND
  per-character system font fallback internally, so each fallback range
  arrives as its own run with its own `IDWriteFontFace`, mirroring the
  per-run CTLine walk. This replaced the originally planned explicit
  `IDWriteTextAnalyzer` + `MapCharacters` + fallback-builder stack; icon
  routing is not a fallback chain either — `sf:`/`sf.` strings resolve to
  the icon font family before shaping (7.5). **Symbol-font caveat (seen
  live 2026-08-28)**: DirectWrite never falls back *out of* a symbol font,
  and Segoe Fluent Icons is one — a part whose `font.family` is the icon
  font shapes regular text to the icon font's `.notdef` boxes. Theme rule:
  PUA glyphs and text never share a part
  (`examples/sketchybar-glass/PORTING-WIN.md`).
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
  premultiplied BGRA8-sRGB, written only by the image pipeline (§7.5): WIC
  decodes converted to `GUID_WICPixelFormat32bppPBGRA` and shell icons drawn
  with `DrawIconEx` then premultiplied. Colour glyph runs are **not**
  rasterized — the atlas is built on `IDWriteFactory2` with no
  `TranslateColorGlyphRun`/D2D path, so emoji and COLR symbols go through the
  grayscale mask page and take the part's colour. Shelf packer, 1 px
  padding, quarter-point size buckets, cache keys, no-eviction policy, and
  the stderr warning strings port verbatim.
- **Metrics — the load-bearing part**: reproduce
  `ShapedLine{width, ascent, descent, inkWidth, inkMinX, inkMinY, inkMaxY}`.
  `ascent/descent` from the layout's `DWRITE_LINE_METRICS` (`baseline` and
  `height − baseline`); `designUnitsPerEm` scales only the per-glyph ink
  boxes. Ink bounds: accumulate per-glyph ink boxes (design metrics or
  `GetAlphaTextureBounds`) advanced along shaped positions, then apply
  **exactly** `width = (int)(inkBounds.width + 1.5)`. Every padding and
  alignment in every ported config depends on this truncation. The headless
  tests in `tests/ink_metric_tests.cpp` pin the truncation and the ink-union
  accumulation with synthetic values; a golden-value comparison against the
  macOS build is still outstanding (§14).
- **Fonts**: spec grammar `"Family:Style:Size"` unchanged; empty family →
  **Segoe UI Variable** with the style-string→weight table
  (`ultralight…black` → `DWRITE_FONT_WEIGHT_*`); named families go straight to
  `IDWriteFactory::CreateTextFormat` with the same style-string table
  (`weightFor`/`styleFor` — `bold`, `semibold` and `italic` match as
  substrings, the rest exactly), so `"Hack Nerd Font:Bold Italic:14.0"`
  resolves to `DWRITE_FONT_WEIGHT_BOLD` + `DWRITE_FONT_STYLE_ITALIC`;
  `FindFamilyName` is used only to pick the icon font. `WM_FONTCHANGE`
  clears the shaped-line font cache — `FontCache::clear`; the glyph atlas
  pages are left as-is, only a display change rebuilds them (late-installed
  Nerd Fonts — same behavior as the CoreText registration notification). It
  must be handled in the **bar windows'** WndProc — message-only windows do
  not receive broadcast messages, so the hidden message window never sees it.
  It is also a convention honored by well-behaved font installers, not a
  system guarantee.

### 7.5 Icons & images

- `sf:<name>` (text) grammar preserved; `sf.<name>` is accepted by the name
  parser but the image pipeline has no `sf.` branch, so an
  `image.string="sf.<name>"` source renders nothing — use `sf:` icon text. The
  resolver maps names through a compiled-in table (`src/render/icon_map.cpp`)
  to Segoe Fluent Icons codepoints (generated from the Microsoft Learn table);
  unmapped names try progressively shorter dotted prefixes
  (`speaker.wave.2.fill` → `speaker.wave.2` → …), then a placeholder glyph
  (U+E9CE) with a one-time stderr note. The icon *font* is chosen at runtime
  from the system collection — Segoe Fluent Icons → Segoe MDL2 Assets →
  `FluentSystemIcons-Resizable` if the user installed it; no font is bundled.
  Tinting via the mask page works unchanged.
- `app.<Name>` image sources resolve running-process icons:
  process enumeration → `QueryFullProcessImageNameW` → `SHGetFileInfoW(SHGFI_ICON)`
  (matched on the executable stem, case-insensitive — no UWP unwrap or
  package-logo lookup, so a packaged app resolves only if its real process
  stem is the name given).
  New Windows-native source `exe.<path>` resolves an icon directly from a path
  — used by the tray popup widget (§10.6) and the sketchybar-glass
  volume-mixer rows.
- File images decode through WIC (`IWICImagingFactory`), multi-res `.ico`
  always decodes frame 0, which WIC's Fant scaler then resizes to
  `size × scale`; `spinner` and `image.rotation` are parsed but **not
  rendered** — `GlyphAtlas::image` has no spinner branch (the source falls
  through to the WIC file path and is negative-cached) and `emitImage`
  ignores `rotation`, so the sketchybar-glass spinner helper draws nothing on
  Windows.

### 7.6 Backdrops

Bar `blur_radius>0` or `glass=on` → `DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE,
DWMSBT_TRANSIENTWINDOW)` (Acrylic; Win11 22621+) + dark mode via
`DWMWA_USE_IMMERSIVE_DARK_MODE` (documented only to darken the frame; that it
also selects the dark backdrop variant is undocumented-but-stable behavior,
the same reliance wezterm ships). A popup's material is Mica (below); the
DWM Acrylic plate on a popup (`popup.blur_radius>0`) is only the fallback
where the wallpaper brush is missing. The DWM backdrops are gated on
Windows' **Transparency effects** setting
(`HKCU\...\Themes\Personalize\EnableTransparency`, read by
`systemTransparencyEnabled()`): with it off they become `DWMSBT_NONE`, and a
popup plate WITHOUT a material is forced opaque
(`buildPopupScene(opaquePanel)`) — a Mica panel keeps its translucent plate,
since its brush paints with the setting off; the daemon re-reads it on
`WM_SETTINGCHANGE`/`WM_THEMECHANGED` (forwarded from the bar windows) and
re-applies the backdrops.
The undocumented `SetWindowCompositionAttribute` accent path is dead on Win11
— never used. Rounded backdrop corners via `DWMWA_WINDOW_CORNER_PREFERENCE`
(popups).

**Per-item glass pills are Mica** (bar and popup surfaces). The reference's gate
(`BarManager.swift`): an item gets a backdrop when `blur_radius > 0`, or when
`background.glass` is on, the background draws, and the fill's alpha is above
0.02 — the fill IS the tint. One difference, and only for an ITEM: a pill's
`blur_radius` also needs `background.drawing`, because the backdrop takes the
plate's rect and that plate only exists for a drawing background. A panel's
rect is the whole window, so a bare `popup.blur_radius` gets a material with
no tint there, exactly as on macOS. For each such plate `buildScene` emits a
`DisplayList::backdrops` entry (the plate's snapped device-px rect and corner
radius; CPU-only, outside the shared ABI) AND a `Hole` at the same rect, so
the bar background is cut under it; the hole flag goes on the bar quad after
all passes, since a pill's hole is only known as its plate is emitted.
`BarSurface::setBackdrops` then syncs the composition host's backdrop layer:
one `SpriteVisual` per entry under the swap-chain visual, painted with
`Compositor.TryCreateBlurredWallpaperBackdropBrush` and clipped by a
`CompositionRoundedRectangleGeometry`, change-guarded and reused by index, so
a static bar touches nothing. The three edges — hole, material, fill — share
one snapped rect and the clip is antialiased, so the corner shows no seam
(measured at 200 %: strip 20 → 29 → 50 across the arc, then the rim).

What the material is, measured: the blurred desktop wallpaper in screen
space and nothing else — a window parked behind the bar does not show
through it (a red window behind, pill stayed neutral grey), and it paints
with Transparency effects OFF, unlike the DWM backdrops above, because it is
a raw compositor brush rather than a policy-following material; that is how
it works at all on a machine with the setting off. Consequently a wallpaper
that is flat under the strip gives flat grey pills a step lighter than the
bar; colour at the top of the wallpaper is what makes the material visible.
`CreateHostBackdropBrush`, the brush that would sample live windows, is
inert for an unpackaged app (paints black) and is not used.

**Popup panels are Mica** by the same gate applied to the panel:
`popup.blur_radius > 0` (the key the reference hangs its frosted panel
material on) or `popup.background.glass` with a translucent plate.
`buildPopupScene(…, backdrops)` emits the panel's snapped rect and corner
radius as a backdrop with NO hole — nothing is painted beneath a panel — and
the plate over it is the tint, exempt from the opaque-when-transparency-off
rule. Glass rows inside the popup go through the same `emitItem` path as
pills: backdrop plus a hole in the panel plate, whose hole flag is set after
the members. That is a Windows extension — the reference gives popup rows no
material and never holes a popup plate — and the shipped theme lights no
rows. The daemon decides `backdrops` before the surface exists
(`PopupSurface::backdropsAvailable()`, the compositor's answer without a
host) because it changes the scene, then syncs the layer after `present()`.
The tooltip bubble rides the same surface with an empty layer.

Fallbacks and limits: `supportsBackdrops()` is false when the brush is
unavailable (Windows 10), and then `SceneParams::backdrops` is off and no
hole is cut, so the translucent fill sits on the opaque strip rather than on
the desktop; a popup falls back to the DWM Acrylic plate (transparency-gated)
and the opaque-plate rule, exactly the pre-Mica behaviour. A square-bottom (graph)
plate gets a rounded hole (single-radius `Hole`), an accepted mismatch. The
visual batch and the swap-chain flip are separate DWM updates, so a reflowing
pill can lead or trail its material by one frame. A closing popup arms
`kPopupCloseTimer` for the length of its fade: the ramp runs on the
compositor with this process rendering nothing, so without it the window
stays shown at zero opacity until the next unrelated pass, and **DWM keeps
drawing its shadow for a shown window** — the panel disappears and its
outline hangs there (measured at 2 s on a quiet bar). Composition opacity
never reaches that shadow; only hiding the window does. A glass row whose plate
overhangs the panel (padding or `background.height` past the 6pt inset) cuts
the panel's border and rim along that edge, because a hole multiplies the
whole quad — fill, border and rim alike; the shipped theme lights no rows.

---

## 8. Core model

`model/` (+ `anim/` for the scheduler and curves) is a 1:1 port of `Items/` +
`Animation/`: Item tree, TextPart/BackgroundStyle value types, YColor
(linear-light lerp), GraphState ring buffer, SliderState, GaugeState,
ImageState, PopupState, bracket derivation and regex member expansion
(**unanchored** substring matching — `std::regex` ECMAScript `regex_search`,
matching NSRegularExpression semantics), five-cursor layout as a pure
function with injected measurement, ComponentGeometry (bracket unions, popup
vertical/horizontal/wrap-flow layouts — `layout.cpp`/`popup_layout.cpp`;
graph tessellation itself is `emitGraph` in `render/scene_builder.cpp`),
Serialize, PropertySetter, and the animation scheduler.

Deliberate fix over the Swift original: `Item.contentWidth` hardcodes
`backingScale: 2` for alias layout (`Item.swift:114`) — irrelevant once alias
is unsupported, and the port measures and lays out in scale-free DIPs (the
injected `Measure` takes no scale), applying the real per-monitor scale only
at scene build (`render/scene_builder` snaps to device pixels) and glyph
rasterization (one `GlyphAtlas` per display scale) — nothing hardcodes a
backing scale (Windows scales are commonly 1.0/1.25/1.5).

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
  notification binding) is **accepted and recorded** — echoed by
  `--query events` (`"(null)"` when absent; `ybar.add_event(name, notification)`
  forwards it the same way) but bound to nothing, with no stderr note. Custom
  events remain fully functional via `--trigger`. (A future named-pipe
  broadcast binding may reuse the slot; out of scope v1.)

---

## 10. Providers

| Provider | Windows implementation | Notes |
|---|---|---|
| Workspace (front app) | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, WINEVENT_OUTOFCONTEXT)` → exe FileDescription (unwrap `ApplicationFrameHost` for UWP) | Always on; no permissions. The hook is the only source — komorebi/YTile do not feed `front_app_switched` |
| space_change | komorebi provider (§11), or the YTile adapter (`src/providers/ytile.cpp`, attached only when komorebi is absent); without either: no-op | INFO stays `""` |
| system_woke / system_will_sleep | `WM_POWERBROADCAST`: `PBT_APMRESUMEAUTOMATIC` / `PBT_APMSUSPEND` (forwarded from the bar windows' WndProc to the message-only mailbox, which never receives broadcasts directly — no `RegisterSuspendResumeNotification`) | |
| app_launched / app_terminated | From komorebi `Show`/`Destroy` window events (or the YTile adapter's manage/unmanage diffs) when a WM is attached; else 2 s process-snapshot diff (`CreateToolhelp32Snapshot`, armed lazily on first subscription) | **Semantics change**: window-scoped with komorebi (background processes invisible); WMI tracing needs admin — rejected. Document. |
| Power | `GetSystemPowerStatus` + `RegisterPowerSettingNotification(GUID_ACDC_POWER_SOURCE, GUID_BATTERY_PERCENTAGE_REMAINING)` → `PBT_POWERSETTINGCHANGE` | Push, no polling. `"AC"`/`"BATTERY"` strings + dedupe/forced split preserved; the third source condition `PoHot` (UPS) maps to `"AC"` |
| Audio | `IMMDeviceEnumerator` → `IAudioEndpointVolume` (+`IAudioEndpointVolumeCallback`), `IMMNotificationClient::OnDefaultDeviceChanged` re-arm | Callbacks marshal to UI thread. Muted → 0, integer percent. **Write path (ybar-win extension, no macOS analog)**: `--volume <0-100>` / `ybar.volume(pct)` → `SetMasterVolumeLevelScalar` on the held endpoint (0 mutes keeping the scalar; >0 sets then unmutes, scalar first so a muted endpoint cannot blip its old level); the set's own `OnNotify` publishes the new value back through the normal path. **Per-app sessions (ybar-win extension)**: `--query audio` / `--volume <0-100> <app>` enumerate `IAudioSessionManager2` on the default endpoint STATELESSLY per call (the tray_icons pattern — no session sinks, no lifetime surface; a fresh manager per call also always sees new sessions). Sessions group by lowercase exe stem (`system` = Explorer's system-sounds session, pinned last); Expired sessions and sessions whose process image path is unreadable (SYSTEM-owned, or the pid died while merely Inactive) are skipped so a group id is never empty; group volume is the max across sessions, muted only when all are. Reads mirror muted→0; writes mirror the master ordering (0 mutes keeping the scalar, >0 sets the scalar then unmutes). Session scalars are RELATIVE to master (100 = follow master) — the Windows 11 Settings mixer convention, kept as-is deliberately. Each group also reports **`background`**: no process running that image owns a visible, titled, unowned top-level window. Keyed by IMAGE and not by the session's pid, because the two are frequently different — Chrome routes audio through a utility process, so a per-pid window test would hide Chrome. The provider only REPORTS it; `--query audio` stays a complete view of the endpoint, and sketchybar-glass's mixer is what drops rows that are `background && !active`. That is what keeps a merely-resident app off the list: closing the Xbox app leaves `XboxPcApp.exe` running (unsuspended, ~100 threads) holding a live Inactive session, and a row for it is indistinguishable from a mixer that failed to refresh. `active` is checked first so anything actually producing sound stays listed even with no window. Caveat: an older UWP app's window belongs to `ApplicationFrameHost.exe`, so such an app reads as background even while visible |
| Network | `NotifyNetworkConnectivityHintChange` + `WlanRegisterNotification` (ACM connect/disconnect); SSID via `WlanQueryInterface(wlan_intf_opcode_current_connection)` | **Win11 24H2 gates SSID behind Location privacy** — degrade to `"connected"` exactly like macOS-without-authorization; `wifi_ssid_prompt=on` opens `ms-settings:privacy-location` |
| SystemStats | `GetSystemTimes` deltas (busy = (kernel−idle)+user), `GlobalMemoryStatusEx` (Total−Avail)/Total; `GetDiskFreeSpaceExA` on `%USERPROFILE%` (else `C:\`) for `DISK_*_GB` | Microsoft explicitly recommends this over PDH for ≥1 Hz sampling. Same 2 s interval, 0–100 contract |
| Media | **GSMTC** (`GlobalSystemMediaTransportControlsSessionManager`, C++/WinRT): `CurrentSessionChanged` + `SessionsChanged` + `MediaPropertiesChanged` + `PlaybackInfoChanged`, plus a 10 s revalidation tick (GSMTC does not reliably report a vanished session — a closed browser tab leaves a `Playing` ghost) → `media_change` with `MEDIA_APP/STATE/TITLE/ARTIST/ALBUM` | Strict superset of the macOS distributed-notification hack: covers Spotify, browsers, most players, plus artwork/seek/transport for a future now-playing popup. `MEDIA_APP` carries the session's app id — scripts matching `"Music"|"Spotify"` need the documented mapping table. Cached-env replay on reload preserved. Fails only under session-0 (not applicable) |
| Clock/routine | 1 s timer on UI thread, tolerance semantics via timer coalescing | |

### 10.1 ScriptRunner

Resolution order for the interpreter of `script`/`click_script`/`ybar.exec`
strings: `%YBAR_SHELL%` if set → `sh.exe` on PATH (Git Bash) → Git for
Windows `usr\bin\sh.exe` located via the `GitForWindows` registry
`InstallPath` (HKCU then HKLM — Git's installer never adds sh to PATH, and
an Explorer-launched daemon otherwise fell back to PowerShell, where every
sh-quoted theme command breaks; Git's sh does NOT self-prepend `/usr/bin`
for `sh -c`, so the shell's directory joins the exe dir in the child PATH
prepend — that is where tr/awk/coreutils live) →
`powershell.exe -NoProfile -Command` (last resort). `%YBAR_SHELL%` is
classified by lowercased **basename** (not the whole path, so a POSIX shell
nested under a `…\cmder\…` tree isn't mistaken for cmd): `powershell`/`pwsh`
→ PowerShell, `cmd`/`cmd.exe` → `cmd /c`, anything else → POSIX `sh -c`; the
value is read with `_wgetenv` so non-ASCII shell paths survive. Dispatch is
`sh -c <script>` / `cmd /c <script>` / `powershell -NoProfile -Command
<script>` by kind, cwd = config dir, 60 s watchdog that closes a
**`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`** Job Object (kills the whole child
*tree* — the latent "children of the shell survive" gap macOS shares is
fixed here), fire-and-forget, PATH prepended with the `ybar.exe` directory
and the resolved shell's directory (`;` separator). `ybar.exec` shares the
interpreter choice, the PATH prepend and the 60 s limit but not the rest: its
watchdog `TerminateProcess`es the shell alone (no Job Object, so grandchildren
can survive) and it passes no cwd, so the child inherits the daemon's working
directory rather than the config dir. The exec pipe is drained concurrently
with the child (same >64 KB deadlock exists with anonymous pipes). Config
scripts: no chmod (no exec bit), dispatch by extension —
`.lua`/`.json`/`.jsonc` in-process, anything else through the resolved shell.
Lua's `io.popen`/`os.execute` go through `cmd.exe` (CRT `_popen`) — document
that these two escape the shell decision.

### 10.6 Alias

`--add alias` and `ybar.add("alias", …)` return
`[!] alias items are not supported on Windows`; `alias.*` property sets on
nonexistent aliases keep the standard error; `--query` never reports
`type=alias`. Rationale: menu-bar extras don't exist, and the notification
area exposes no per-icon capture API.

A tray **popup widget** shipped instead (`src/providers/tray_icons.h`;
theme `items/widgets/apps.lua`): rows carry the owning app's registration
name and its icon (Explorer's stored `IconSnapshot` PNG — the tray icon as
it was at first registration, read from the registry and content-hashed into
`%LOCALAPPDATA%\ybar\tray` — where the registration kept one, else
`exe.<path>` through §7.5) — resolved metadata, not captured tray pixels, so
it does not revive the `alias` grammar. Left-click opens or restores the
app; right-click quits it behind an in-row confirm.
Two claims in this section's original rationale were measured false on
26200.9168 and are recorded so they are not re-derived:

- Tray icons are **not** toolbar buttons. The `TrayNotifyWnd` > `SysPager` >
  `ToolbarWindow32` + `TB_GETBUTTON`/`TRAYDATA` technique is dead on 22H2
  Moment 2+: `TrayNotifyWnd` is an empty leaf and no `ToolbarWindow32`
  exists anywhere in the session.
- UIA is **not** a sufficient source. It sees only the icons promoted onto
  the taskbar (1 of 11 here), because the overflow flyout's host window is
  created on demand and destroyed on dismiss; and even with that window
  forced open it reported an empty `Name` for 3 of 10 overflow icons.

The list therefore comes from `HKCU\Control Panel\NotifyIconSettings`
filtered by process liveness — a **two-pass** enumeration (basename
candidates first; handles, icon and version metadata only for survivors),
because opening a handle on every process from the UI thread measured 50 ms
warm / 225 ms cold. Liveness matches on the registration's
**full image path**, falling back to executable **basename** only for
processes whose path cannot be read (NVIDIA's icon is owned by a SYSTEM
`NVDisplay.Container.exe` whose full path a normal process cannot read; a
stray row beats a missing one). Explorer's own icons are omitted — they all
report `explorer.exe`/"Windows Explorer" and the bar already carries those
functions as first-class pills.

The verb surface: `--query tray` / `--query windows` (§3.6), `--window <hwnd>
close|kill` (an hwnd from the `--query windows` rows: posted `WM_CLOSE`, or
`TerminateProcess` with no save prompt), `--tray <name> invoke|close`, and
the in-process `ybar.tray(name, action)` (§3.7).
`invoke` tries, in order: (1) UIA `InvokePattern` — the real tray callback,
prefix-matched because UIA labels carry status text the registry name lacks;
it only reaches promoted icons or an already-open overflow flyout; (2)
restoring a window of a **full-image-path-verified** PID — candidates
ranked minimised first, else visible, and **never a merely-hidden window**:
the first titled non-owned window is often an internal one the app hid on
purpose (OneDrive's "GDI+ Window", SecurityHealthSystray, Radeon Software),
so an app with nothing minimised or visible falls through to (3)
`ShellExecute` on the owner, letting its own single-instance handling decide
what to surface. `close` is Task Manager "End task" semantics: `WM_CLOSE` to
every window the owning processes have, then a terminate five seconds later
for whatever is still alive **and** no longer showing a window (still
showing one = mid-prompt with the user, spared). Kill targets are confirmed
by **full image path**, never basename — a basename is not an identity: a
dormant registration for the packaged Claude desktop app matched three
unrelated Claude Code CLI processes on the author's machine. A process
whose path cannot be read is never terminated, `explorer.exe` is refused
outright, and terminate rights are requested up front so anything at higher
integrity drops out without a blocklist. The theme reconciles the row list
at 1.5/4/7 s after a close — spanning the `WM_CLOSE` reply and the
escalation — each pass still gated on the popup being open, since the next
open re-populates anyway (`mouse.exited.global` hides it the moment the
pointer leaves).

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
the display string. Monocle/maximized state is not read; `fullscreen_show`
stays driven by the surface's foreground-window check, which the daemon
re-runs whenever a workspace-change update lands.

Parsing rule: **tolerant** — unknown fields ignored, missing optionals
defaulted; the schema has no formal stability guarantee (no breaking changes
documented in the last five releases, but pin the tested version in CI and
re-validate per release).

### 11.3 KomorebiProvider (daemon-side, attempted while `reserve` allows a WM)

- Detect komorebi: `komorebi.sock` exists (`GetFileAttributesA`, no connect
  attempt; a late attach `refresh()`es state at once; also re-checked from the
  daemon's 1 s tick when absent so a bar started before komorebi attaches
  itself).
- Subscribe as the fixed name `ybar.sock` (socket
  `%LOCALAPPDATA%\komorebi\ybar.sock`; every ybar instance uses this same
  name — the instance lock (§5) stops a second launch of the same instance
  from re-registering it, but a differently named instance would clobber the
  live subscriber). Reader thread: accept → read-to-EOF → parse →
  `PostMessage` to UI thread.
- **Reconnect** (komorebi-bar's pattern, one fix): a zero-byte read / accept
  failure ⇒ komorebi died; loop re-registration every 1 s until it succeeds,
  then re-apply the work-area offset (§11.4) and re-publish state.
  Re-register with `AddSubscriberSocketWithOptions` — komorebi-bar re-sends
  the plain variant here and silently loses its state filter after a
  reconnect; don't copy that.
- **Unsubscribe** on stop (`--exit`, `reserve` leaving WM mode, provider
  teardown): close the listener, join the reader, send
  `{"type":"RemoveSubscriberSocket","content":"ybar.sock"}` to `komorebi.sock`,
  and delete the subscriber socket file; the daemon then zeroes the work-area
  offset (§11.4).
- Events published on the YBar bus:
  - `space_change` (built-in) + **`komorebi_workspace_change`** (registered by
    the provider as a custom event) with env
    `FOCUSED_WORKSPACE=<name-or-index>`, `PREV_WORKSPACE=…`,
    `FOCUSED_MONITOR_INDEX=<1-based>`, `WORKSPACES=<names>` (the focused
    monitor's workspace display names, newline-separated, komorebi order),
    `FOCUSED_WORKSPACE_INDEX=<1-based position in WORKSPACES>`, INFO =
    focused workspace display string — fired on any notification whose
    focused monitor/workspace changed, or whose workspace list (names/count)
    changed. Themes keep the AeroSpace pattern (subscribe, read
    `env.FOCUSED_WORKSPACE`) verbatim.
  - `front_app_switched` is not derived from `FocusChange`: it comes only from
    the foreground-window source (`publishFrontApp`, §10), so items see one
    event.
  - `app_launched`/`app_terminated` from `Show`/`Destroy` (window-scoped,
    §10 table).
  - No raw passthrough: the notification JSON is not cached and there is no
    `--query komorebi` verb (`--komorebi` is send-only, no reply). A script that
    needs the full State asks komorebi directly (`komorebic state`, or
    `{"type":"State"}` on `komorebi.sock`) or uses the event env.
- **Forced-query** entries added: `komorebi_workspace_change` (and
  `ytile_workspace_change`) re-query the live WM (`refresh()` —
  `{"type":"State"}` on `komorebi.sock`, or YTile's `state` command — dedupe
  bypassed) so `ybar --trigger komorebi_workspace_change` replays current
  state at config boot, mirroring the AeroSpace boot-population idiom.
- **YTile (sibling WM)**: `YTileProvider` (`src/providers/ytile.*`, named pipe
  `\\.\pipe\ytile`, NDJSON) attaches at boot and through the same 1 s re-detect
  only while `komorebi.sock` is absent; komorebi outranks it and takes over live
  if it appears later. It publishes `ytile_workspace_change` **and**
  `komorebi_workspace_change` (plus `space_change`) with the same env keys
  (`FOCUSED_WORKSPACE`, `PREV_WORKSPACE`, `FOCUSED_MONITOR_INDEX`, `WORKSPACES`,
  `FOCUSED_WORKSPACE_INDEX`) — `WORKSPACES` there carries the shown workspace
  numbers (non-empty or active) rather than names — so komorebi themes run
  unchanged.

### 11.4 Work-area reservation handshake

On start / bar-height change / monitor change / komorebi reconnect, when
`reserve=komorebi`:

```json
{"type":"MonitorWorkAreaOffset","content":[<monitor_idx>, {"left":0,"top":H,"right":0,"bottom":H}]}
```

per komorebi monitor (indices `0 … monitors.elements.size()-1`, regardless of
ybar's display include set). **Both `top` and `bottom` are `H`**: komorebi
applies `top += offset.top; bottom -= offset.bottom` where `bottom` is the
work-area *height* — `top` alone would shift the area down without shrinking
it, pushing tiles `H` px past the bottom of the screen (komorebi-bar sets
both, `bar.rs:503`). `H` = **physical pixels** of
`(height + y_offset) × scale of the first bar surface` — a single value sent
to every monitor (komorebi rects are physical; komorebi-bar's un-scaled
constant is a known limitation, we do better) and `monitor_idx` is simply
komorebi's own index `0 … N-1` — every komorebi monitor receives the same
offset; no `device_id`/geometry matching is done. On graceful exit
(`--exit`, `WM_ENDSESSION`): send the same message with a zero rect.
Known limitation (komorebi-bar has it too): a crashed bar leaves the offset
until komorebi reloads its config — document `komorebic restore-windows` /
config reload as the fix (still to be written up in the README/example);
ybar does not pre-zero at start — komorebi stores the offset per monitor
(`work_area_offset`, an absolute set), so applying `H` replaces the stale
value.

### 11.5 Click commands

Two supported forms:

- **Compat (themes port verbatim)**: `click_script = "komorebic focus-workspace 2"`
  — shells out, works everywhere.
- **Native (no `komorebic` spawn)**: CLI `ybar --komorebi '<json>'` (from Lua
  via `sbar.exec("ybar --komorebi '…'")`, as
  `examples/sketchybar-glass/items/spaces.lua` does; there is no
  `ybar.komorebi` Lua function) — the daemon writes the message straight to
  `komorebi.sock`. Useful messages: `FocusWorkspaceNumber(n)`,
  `FocusMonitorWorkspaceNumber(m, n)`, `FocusNamedWorkspace(s)`,
  `CycleFocusWorkspace(dir)`, `TogglePause`. The daemon forwards whenever
  `komorebi.sock` exists (even with `reserve=off`); with komorebi absent and
  YTile attached, `FocusWorkspaceNumber` (index into `WORKSPACES`),
  `FocusNamedWorkspace` and `CycleFocusWorkspace` are translated onto YTile
  verbs; anything else — or no WM at all — replies
  `[!] komorebi is not available`. This is a ybar-win extension; the macOS
  build rejects the verb.

### 11.6 Workspaces widget & pairing example

`examples/sketchybar-glass/items/spaces.lua` is the komorebi workspaces
widget: a simplified form of the AeroSpace one (fixed 10-slot pill set, focused
highlight; no reveal/collapse animation, no app glyphs) that is
**event-driven with zero polling**: the daemon's
`WORKSPACES`/`FOCUSED_WORKSPACE_INDEX` env replaces all three `aerospace list-*`
CLI calls (enumeration = `workspaces.elements` of the focused monitor; every
listed workspace is shown — the env carries no per-workspace occupancy, so
there is no non-empty ∪ focused filter, and `helpers/app_icons.lua` is present
in the example but unused by the pills).
Click = `ybar --komorebi '{"type":"FocusWorkspaceNumber","content":<slot-1>}'`
(native form, index-based so unnamed workspaces focus too). Note komorebi
workspaces are **per-monitor and dynamic** — re-enumerate pills on state
notifications, not only at config load.

`examples/komorebi-whkd/` replaces `examples/yabai-skhd/` — today only a
six-line README stub; the planned contents are a komorebi.json fragment (bars
should NOT also set `global_work_area_offset` when `reserve=komorebi` — ybar
sends it), whkd bindings firing `ybar --trigger …` (mode-pill pattern like
skhd modes), and the pairing walkthrough. No SIP/scripting-addition section —
komorebi needs no OS tampering.

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
  file) ports as the built-in `ybar theme list|current|use <name>|reset`
  subcommand — there is no install-from-git; user themes are directories
  dropped into `~/.config/ybar/themes/`; shipped themes get komorebi workspace
  widgets and `ms-settings:` deep links (`ms-settings:sound`,
  `ms-settings:batterysaver`, `ms-settings:network-wifi`) replacing
  `x-apple.systempreferences:` clicks; `osascript` media/volume snippets are
  obsolete — media is native (GSMTC) and volume goes through the audio
  provider (`volume_change` in) and, for absolute sets from sliders, the
  in-process `ybar.volume(pct[, app])` Lua verb / `ybar --volume <0-100> [app]`
  CLI verb (§10, Audio row) — no shell round-trip.

---

## 13. Packaging & distribution

- **winget manifest + scoop bucket** (komorebi precedent for a CLI+daemon
  hybrid); chocolatey on demand. Prebuilt zip, Authenticode-signed in CI
  via Azure Trusted Signing (§15 punch-list item 2) — Smart App Control
  makes that load-bearing rather than a nicety, and SmartScreen still
  warns until the certificate accrues reputation.
- Static CRT (`/MT`) → single `ybar.exe` + `shaders/` + `examples/` (the
  shipped themes; `ybar theme list` searches beside the exe) + an app-local
  `d3dcompiler_47.dll` payload.
  No TCC/codesign/bundle apparatus — that entire macOS surface evaporates.
- Identity: `AppUserModelID = "YBar.YBar"` (taskbar/notification identity;
  successor to `com.ybar.YBar`).
- Autostart: `ybar autostart enable|disable|status` writes/removes/reports a
  `YBar` value (quoted, symlink-resolved exe path) under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` (visible in Task
  Manager's Startup Apps, user-toggleable). Crash-restart semantics (macOS
  LaunchAgent `KeepAlive.SuccessfulExit=false`) via an optional Task Scheduler
  recipe (not yet written — today the Run value starts ybar once per login and
  nothing restarts it after a crash); `ybar --exit` remains the only
  sanctioned stop.
- Build dir: in-tree — `CMakePresets.json` puts the `default` (Debug) preset
  at `build/` and `release` at `build-release/` (`build/` is git-ignored;
  `build-release/` is not), so be aware that the repo may live in
  OneDrive-synced folders (this one does); same hazard class as the
  iCloud/xattr issue that motivated the macOS scratch path.

---

## 14. Testing & CI

- Port the ~90 platform-neutral tests (wire framing, tokenizer, colors +
  linearization, curves, FontSpec parsing, layout invariants incl. q/e and
  width=dynamic sentinel, property paths, defaults, event bits +
  NAME/SENDER/INFO protection, JSONC translation with sorted output, glyph
  clip UV-remap math, Lua end-to-end with headless BarManager) to Catch2.
  The headless seam is `LuaRuntime` itself, not the daemon (`runDaemon()`
  creates its message window and reserves the instance socket before anything
  else): the tests build it with a null message window over the real
  `ItemStore`/`EventBus`/`CommandHandler`/`ScriptRunner` funnel — no window,
  socket, or daemon; `exec`/`delay` degrade to no-ops — so the Lua end-to-end
  tests run in CI. The Swift tests keep the same seam (a `BarManager` without
  `begin()`) deliberately.
- **Text-metric parity suite**: golden `ShapedLine` values (width per the
  +1.5 formula, ink bounds) exported from the macOS build for a fixed test
  font shipped in the repo; DirectWrite must match integer-exactly.
- **komorebi protocol tests**: recorded notification/State JSON fixtures from
  v0.1.41 (checked in) parsed by the provider; a canary CI job runs against
  komorebi's latest release to catch schema drift.
- CI: GitHub Actions `windows-latest`, CMake presets against the runner's
  preinstalled vcpkg (`VCPKG_INSTALLATION_ROOT`; no dependency cache step);
  PresentMon-based idle-GPU smoke test on a self-hosted runner is
  aspirational, manual acceptance otherwise.

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

### Implementation status (as of 2026-09-02, all live-verified on hardware)

**Done** — W0 (wire + komorebi protocol + HLSL, incl. a live State round-trip);
W1 (bar windows — since moved to Windows.UI.Composition for §7.6 — SDF
background);
W2 mostly (DirectWrite stack, atlas, layout, full CLI — the advance-based
widths and missing icon mapping are both closed below; only the §14 macOS
golden-value gate stays open); W3 mostly (EventBus, ScriptRunner, mouse +
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
graphs/sliders(render)/gauges — all three since landed, see below).

**Also done since**: the embedded Lua runtime (vendored 5.4.8, byte-identical
prelude, single-funnel trampolines, generation-guarded exec/delay, Lua-first
dispatch) — live-verified with in-process closures driving the komorebi
workspace pill and the CPU gauge. An in-tree **YTile provider** extension
mirrors the komorebi update flow (fires `komorebi_workspace_change` for
config compatibility); its wire contract is `docs/YTILE-IPC.md` in the
sibling YTile repo (see the YTile parity paragraph below). **Popups + tooltips**
(layouts §3.9; panel lifecycle + ordering §6): vertical/horizontal/wrap
layouts, per-host panels, WH_MOUSE_LL outside-click auto-close,
press-on-bar-closes-others, 600 ms tooltip dwell —
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

**Also done**: Acrylic backdrops (§7.6) for bars and popups, per-pill Mica
backdrops and Mica popup panels (§7.6; both surfaces moved to
Windows.UI.Composition for them, DirectComposition remains only as the
frame pump's clock), `ybar theme
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
2. ~~Signing~~ — DONE: Azure Trusted Signing, from CI, as a managed
   identity over OIDC (no certificate file, no stored secret). `ci.yml`
   signs every dev artifact — SAC blocks fresh unsigned binaries often
   enough that live-verifying a dev build became a coin flip — and
   `release.yml` signs `dist/ybar.exe` **before** packaging, so the
   zip hash the winget and scoop manifests pin covers the signed bits.
   Verified on the running build: `Get-AuthenticodeSignature` reports
   `Valid`. Both paths skip while the `AZURE_CLIENT_ID` repo variable is
   empty, so forks still build; the release body then says so.
3. ~~Cutting the first `win-v0.1.0` tag~~ — DONE 2026-09-01: tagged and
   published signed (see the release + mixer pass below); the scoop manifest
   pins the zip hash, the winget manifest still carries its all-zero
   placeholder pending submission.
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

**Signing close-out (2026-09-01)**: the SAC block above is resolved, and
the on-screen verification it was holding up went ahead on 2026-08-28 (the
reworked bluetooth and wifi flyouts, which caught the symbol-font .notdef
bug now written up in §7.4). Signing itself landed as Azure Trusted
Signing rather than the OV certificate first chosen: since the 2023-06
CA/B baseline an OV key must live on hardware, which would have meant
signing manually on the maintainer's machine *after* each release and
re-uploading the asset — hosted CI can never hold that key. Trusted
Signing has no key to hold: the runner authenticates as a managed identity
over OIDC and the service signs. Both workflows sign; the release does it
before packaging so the published hash is the signed one. The signature
reads `Valid` on the deployed build.

**Post-signing feature pass (2026-08-29 → 09-01)**, all CI-green (the
Catch2 suite now counts 188 test cases) and live-verified on hardware:

- **Fullscreen auto-hide** (§6): the bar showing over fullscreen apps traced
  to the theme's `fullscreen_show=true`; the policy was reworked so `off`
  (now the theme default) auto-hides the monitor's bar. Adversarial review
  of the feature caught the `WM_DISPLAYCHANGE` rebuild recreating bars
  *shown* without moving the foreground — a ~1 s flash over fullscreen —
  fixed by re-evaluating at the end of `rebuildSurfaces()`. A follow-up
  ANDed `SHQueryUserNotificationState` into the detector after geometry
  alone hid the bar under a merely-maximized borderless window
  (user-reported).
- **Graph baselines** (§3.9): zero-sample stroke clamped inside the plate,
  reference `stepX = width/(count−1)` spreading, border-inset graph box,
  and squared bottom corners on a graph item's plate and shadow.
- **`slider.interactive` + battery meter** (§3.3): the battery pill became
  a slider used as a continuous fill meter, which surfaced the
  press-path overwrite recorded in §3.3 (real 63% read back 95% on click);
  found by code review of the widget work, regression-tested.
- **Tray widget** (§10.6): rebuilt from a UIA walk to the registry
  registration list, grew real row icons, `invoke`/`close` verbs with the
  candidate ranking and full-image-path kill confirmation recorded there,
  and the in-process `ybar.tray` binding (§3.7).
- **`image.desaturate` / `image.y_offset`** (§3.3): the closing tray row
  greys its colour icon; row icons sit on the label's optical centre.
- **Wifi rows** (theme): every row shares two columns. Segoe Fluent's
  `Wifi1..Wifi4` are *proportional* — leading with the variable-width arc
  shifted everything after it in the run (badges wandered 100/97/94/90 px),
  so rows lead with the fixed-width glyph. An indent computed from paddings
  alone came out ~8 pt short — a part without a fixed width advances by its
  ink as well as its paddings, and a fixed width replaces both — so a row's
  *structure* is matched to the reference row instead of tuning an indent.
- **Three defects found live, none feature-related**: `FontCache::shape()`
  could `clear()` the cache while callers held references into it — every
  call site shapes an icon then a label and holds both — so the cap moved
  to a new `beginFrame()` at the top of `renderAll()`, the one point where
  no shaped reference is live. A resolution change could silently leave a
  healthy daemon with **zero bar windows** for the rest of the session
  (both `rebuildSurfaces()` failure paths were silent `continue`s, and the
  500 ms debounce can land while the display stack is still settling) —
  now logged and retried from the 1 s tick with 1→60 s backoff, and
  `resize()` unbinds the render target before `ResizeBuffers` and checks
  the HRESULT. And the monitor clamp pinned an edge-adjacent popup flush
  against the bezel — the clamp now stops the theme's 7 pt short, left
  clamp applied after right so an over-wide popup overflows rightwards
  rather than off-screen.
- Theme pass: near-black strip, darker pills, CPU as a fill meter, no
  front-app label, equalised pill gaps; media marquee duration scales with
  `utf8.len` for a constant ~45 pt/s reading pace (the fixed 100-frame
  default raced long titles).

**Release + mixer pass (2026-09-01 → 09-02)**, CI-green (the Catch2 suite
now counts 195 test cases) and live-verified on hardware:

- **win-v0.1.0 shipped**: the release workflow signs under
  `environment: release` (the OIDC subject the federated credential
  actually matches — the first run failed on the tag-subject mismatch);
  install channels are the `scripts/install.ps1` one-liner (SHA256 +
  Authenticode-verified) and the raw scoop manifest, both README-led.
- **Slider knob centred** (theme note in `items/widgets/bluetooth.lua`): the
  Segoe `●` stand-in's ink sits ~1.75 px low in its em at 2× (the SF
  circle's is symmetric), so both themes' knobs — now 18 pt, a 16 px circle
  at 2× — carry `y_offset = 2.25` (1.25 centred the default 11.5 pt; the sag
  grows with size), measured by a held-open pixel sweep — re-probing popups
  between captures shifts layout sub-pixel and poisons deltas; sweep with
  the popup held open.
- **Per-app mixer** (§10 Audio row, §3.6, §3.7): `--query audio` /
  `--volume <0-100> [app]` / `ybar.volume(pct[, app])` over a stateless
  per-call `IAudioSessionManager2` enumeration (tray_icons pattern — no
  session sinks, no lifetime surface), grouped by lowercase exe stem with
  unreadable-path and Expired sessions skipped so a group id is never
  empty. The bluetooth flyout's volume row gains the quick-settings
  chevron; the popup moved to wrap-flow (`wrap_width = popup_width + 4` —
  line advance includes the default 2/2 item paddings, reproducing the
  vertical layout pixel-for-pixel) so the master line seats slider +
  chevron and each mixer row seats icon + slider, icons deliberately
  outside the slider items (slider clicks clamp x to 0-100, reference
  parity — an inset icon would be click-to-mute). The panel resets to the
  master view on open because auto-close popups close on silent paths that
  run no Lua. Live-verified end to end: query contract against three real
  groups, set/mute/restore round trips, chevron open, back row, and a
  synthetic 65 %-mark drag on the Chrome row landing at exactly 65 with
  the master untouched.

**Docs audit + footer pass (2026-09-02)**, the Catch2 suite now counts 196
test cases:

- **Battery popup footer** (theme): the Settings row's `sf.gearshape` image
  drew nothing (the atlas has no `sf.` source) but reserved its width, so
  "Settings" sat 19 pt right of every other row. The gear is now an `sf:`
  icon part beside a label part. Two slot rules recorded in the theme: a
  part's fixed `width` replaces its ink and paddings (an 11 pt inset inside
  a 16 pt slot clipped an 11 pt glyph to its left half), and an item centres
  its parts by default, so a row's slots must sum to the popup width — also
  the real cause of the wifi rows' "8 pt origin" puzzle above.
- **Documentation audit**: every document on the branch (this spec, the
  README, packaging, the porting guide, the per-directory READMEs) was read
  against the code by 22 auditors and each finding re-verified by
  adversarial refuters; about 170 corrections landed. The recurring drift:
  the YTile adapter lived only in this status log; §7 still described the
  design (device-lost recreation, colour glyph runs, a bundled icon font,
  `sf.` images, `spinner`) rather than what shipped; §11 described a
  `--query komorebi` verb and per-monitor matching that never existed. The
  `sf.` image source and `spinner`/`image.rotation` are now recorded as
  **not rendered** (§7.5) rather than fixed.
- **Two code slips the audit surfaced, both fixed**: `image.drawing` and
  `background.image.drawing` had their reference error strings swapped
  (§3.3; regression-tested), and the app-lifecycle poller's gate tested only
  komorebi, so under YTile it armed beside the window diffs and every launch
  fired twice (§10).
- `cmake_minimum_required` moved to 3.25: `CMakePresets.json` is schema
  version 6, which 3.24 rejects at configure.

Deliberate divergences (never 1:1): alias items but a tray widget + verbs +
`ybar.tray` instead (§10.6, §3.7), the `--volume` verb + `ybar.volume`
write path on the audio provider plus the `--query audio` /
`--volume <pct> <app>` per-app session mixer (§10, §3.6, §3.7), the added
`slider.interactive` / `image.desaturate` / `image.y_offset` keys and bar
`reserve` (§3.3, §6.1) with the desaturate shader flag behind them (§7.3),
graph baseline clamping and squared plate bottoms (§3.9), per-item glass
pills as Mica rather than Liquid Glass, rim kept, popup panels as Mica rather
than frosted glass, and glass popup rows with their own material (§7.6),
distributed-notification bindings (§9), THERMAL_STATE always
`nominal` (§3.5), single topmost z-band (§16).

---

## 16. Risk register

- **DirectWrite ink-metric parity** — the +1.5 truncation over glyph path
  bounds has no single-call DWrite equivalent; per-glyph accumulation may
  differ by a pixel on some fonts. Mitigation: the accumulation math and the
  +1.5 formula are pinned headlessly (`tests/ink_metric_tests.cpp`); the
  macOS golden-value export (§14) is still open past W2 — cross-platform
  pixel equality remains unproven.
- **komorebi schema drift** — no formal stability guarantee; the tagged serde
  output could change variant names. Mitigation: tolerant parsing,
  pinned fixtures + latest-release canary CI, all komorebi coupling isolated
  in one provider.
- **Stale work-area offset on crash** — offset persists in komorebi until
  config reload. Mitigation: the first `MonitorWorkAreaOffset` after start
  replaces (never adds to) whatever komorebi still holds, so a stale strip is
  overwritten on every reserving ybar start; document recovery; consider a
  `komorebic` health-check on `--exit` paths.
- **Shell compatibility** — configs written on macOS assume POSIX sh + macOS
  tools (`pmset`, `osascript`, `open`). The shell resolution (D10) keeps the
  *interpreter* compatible; the *commands* still need theme-level Windows
  variants. The Windows theme tree ships the Windows variants only
  (`examples/sketchybar-glass`, with `helpers/win.lua` standing in for the
  macOS `helpers/mac.lua`); `PORTING-WIN.md` covers the rest.
- **WS_EX_NOACTIVATE / topmost quirks** — some fullscreen apps and
  DirectComposition interactions can still push topmost windows around;
  `fullscreen_show`'s two-signal detection path (§6) is the mitigation.
- **GSMTC session mapping** — `MEDIA_APP` values differ from `"Music"/"Spotify"`
  literals in existing scripts; no mapping table ships — the flagship theme
  drops the whitelist and shows the raw id as-is
  (`examples/sketchybar-glass/items/widgets/media.lua`, `PORTING-WIN.md`).
- **C++/Lua longjmp** — enforced by review, with no debug assertion —
  non-raising stack helpers (`toString`/`argCString`, `lua_rawlen` over
  `luaL_len`) are the only guard that no trampoline path calls raising Lua
  APIs (same invariant as Swift).
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
