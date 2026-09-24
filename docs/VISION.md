# YBar — Vision

**YBar is Waybar for macOS**: a highly customizable, GPU-rendered status bar that replaces (or augments) the macOS menu bar, rendering complex graphics and animations at full speed via Metal, and extensible the way sketchybar is — scriptable from any language, with first-class Lua configuration. That was the founding statement and it still describes the macOS engine; a native Windows 11 port has since shipped beside it, mirroring the same command grammar, wire format and Lua API on Direct3D 11 (see [WINDOWS.md](WINDOWS.md)).

## Why

- **sketchybar** proved the model: an imperative CLI/IPC-driven bar where *everything* is an item you compose from scripts. But it draws with CoreGraphics on the CPU, animations are limited, and complex configs (graphs, many items, frequent updates) burn CPU.
- **Waybar** proved the ergonomics: declarative module config, powerful styling, a huge built-in module library, and a trivially simple `custom` module contract.
- **YBar** combines both on a Metal renderer: sketchybar's composable item/event/IPC architecture, Waybar's batteries-included modules and approachable config, and a GPU scene graph that makes 120 fps animations, live graphs, blurs, and shader effects essentially free.

## Product pillars

1. **Metal-first rendering.** A retained scene graph rendered by Metal (instanced SDF quads + glyph atlas text). Damage-driven: zero GPU work when the bar is static, and when animating paced to the slowest hosted display, up to 120 Hz. Complex visuals — gradients, shadows, squircles, live graphs, shader-driven effects — at negligible cost.
2. **sketchybar-compatible mental model.** Items with `icon`/`label`/`background`, positions `left|center|right`, brackets/groups, popups, `--add/--set/--subscribe/--animate/--trigger/--query` style commands over IPC, executable config script, plugin scripts receiving `$NAME/$SENDER/$INFO` env vars. Migrating a sketchybar config should feel mechanical, not a rewrite.
3. **Batteries included (Waybar-style).** Native Swift providers for the common modules so a useful bar needs zero external scripts: clock/calendar, battery, volume/audio device, wifi/network, cpu/memory, disk, now-playing, front app, spaces/workspaces (native + yabai/AeroSpace integration), and more.
4. **Extensible in layers.**
   - *Level 0:* declarative config for built-in modules (no code).
   - *Level 1:* shell/any-language plugin scripts via events + CLI (sketchybar model).
   - *Level 2:* embedded Lua API (SbarLua-style) for rich programmatic configs.
   - *Level 3:* native Swift plugin protocol for custom scene-graph nodes / shaders.
5. **Good citizen.** Public APIs only: the engine and every shipped binary link and dlsym-resolve nothing private — no SkyLight/CGS symbols — so a capability that needs one is not built and an OS release cannot break the bar. The single exception in the repo is an opt-in example helper, `examples/sketchybar-port/helpers/menus` (app-menu swap), which links SkyLight, is built only by `make helpers` from a clone, and ships in no install — see [its README](../examples/sketchybar-port/README.md). The engine itself keeps one undocumented-ABI read: `WifiScan` peeks `CWNetworkProfile`'s private `_isPersonalHotspot` flag through the public Objective-C runtime (`class_getInstanceVariable` + `ivar_getOffset`, presence- and type-checked) to list saved personal hotspots in the Wi-Fi popup, and lists none if either check fails — nothing private is linked or dlsym-resolved for it. Low idle CPU (<0.1%), low memory, instant hot-reload.

## v1 module targets

Informed by a real-world heavy sketchybar setup (Lua, popups, sliders, graphs, helper binaries):

| Module | Notes |
|---|---|
| workspaces | native Spaces + AeroSpace/yabai integrations, per-space app icons |
| front_app | app name + icon |
| clock/calendar | popup with month view + EventKit events |
| battery | charging states, popup with health details, slider support |
| volume | slider, output device, Bluetooth device names |
| wifi | SSID (with location-permission handling), link status |
| cpu / memory | live graph primitive |
| media / now-playing | shipped over distributed notifications (Music/Spotify), never MediaRemote — it is entitlement-locked; the Windows port uses GSMTC |
| custom | Waybar-style `exec` + interval/event scripts |

## Primitives (renderer-level)

Item, text run (font fallback, SF Symbols, emoji), image, rounded-rect/squircle background (border, gradient, shadow, blur), graph, slider, group/bracket, popup (anchored panel), spacer/separator. All properties animatable with curves.

## Non-goals (v1)

- Linux support. Windows was a v1 non-goal too, and no longer is: a native
  Windows 11 port ships as a separate C++ engine on the orphan `windows`
  branch, sharing the command grammar, IPC wire format and Lua API rather than
  any Swift code (see the README).
- Replacing menu bar *extras* hosting (NSStatusItem tray). The narrower
  alias/capture of individual extras has since shipped (`--add alias`, via
  ScreenCaptureKit).
- A GUI settings app.

## Repo

`https://github.com/NineFiveB/YBar.git` — Swift Package Manager, Swift 6, macOS 14+ (SDK current), `ybar` single binary acting as daemon + CLI client.
