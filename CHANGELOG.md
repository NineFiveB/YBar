# Changelog

All notable user-visible changes to YBar for macOS, newest first. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the Windows
port on the `windows` branch has its own git history. Each release heading is
`## [<version>] — <date>`: the release workflow refuses a tag that has no such
section and publishes the section as the GitHub Release notes.

## [Unreleased] — 0.2.1

### Added

- `ybar start [-c <path>]`, `ybar stop`, `ybar restart [-c <path>]` and
  `ybar status`: process control that launches YBar.app rather than the
  bare binary, so privacy prompts stay attributed to YBar, and goes through
  launchd when a login job owns the bar. `make start`, `make restart` and
  `make status` wrap them; `make stop` runs `ybar stop` in place of
  `--exit`. The formula's caveats point at `ybar start` and
  `ybar autostart enable`; `brew services` stays deliberately unwired.

### Fixed

- Wi-Fi: a join that `networksetup` refuses with exit 0 and a message
  ("Could not find network …", "You cannot join a network when Wi-Fi power
  is off.", "All Wi-Fi network services are disabled.") is reported as a
  failure; it used to dismiss the panel as joined and hand Lua 0.
  `networksetup` prints nothing on success, so the verdict is now "exit 0
  and silent".
- Wi-Fi: a password join that hangs until the 30 s watchdog is reported as
  a timeout — "Timed out joining <name>." in the panel, which stays open
  for another try — instead of "Couldn't join. Check the password and try
  again."
- Wi-Fi: Cancel and Escape work while a join is in flight; the
  `wifi_prompt` callback receives `("", 2)`, as on any close that did not
  join, and the pill catches up on the next `wifi_change`.
- Wi-Fi: without the Location grant, `wifi_scan` hands Lua exit code 3
  instead of an empty success, the joined network is still listed under the
  literal "<redacted>", and the ysuite-liquid popup says "Allow Location
  for YBar to list networks" over the opt-in command instead of a spinner
  that ends in nothing.
- Wi-Fi: the personal-hotspot flag, read from `CWNetworkProfile`'s private
  `_isPersonalHotspot` ivar, is type-checked (a one-byte `BOOL`) as well as
  presence-checked and degrades to "no hotspot rows" otherwise; the source
  now says plainly that it is a read-only ivar peek with no supported way
  to ask.
- ysuite-liquid: the Wi-Fi pill and popup header derive "connected" from
  `wifi_change` and the scan rather than `ipconfig getifaddr en0` (en0 is
  Ethernet on a desktop Mac); a stale SSID no longer lingers after a
  disconnect, and the widget re-seeds itself so a config reload does not
  leave it silent.
- ysuite-liquid: the Wi-Fi scan spinner runs only while the popup is drawn
  (it used to tick a hidden row every 40 ms on every `wifi_change`), and a
  `wifi_change` that arrives mid-scan queues one follow-up scan instead of
  being dropped.
- ysuite-liquid: the CPU card's temperature aside starts empty and fills
  only when `helpers/system_stats_rich.sh` reports a positive `CPU_TEMP`
  (it needs an `osx-cpu-temp` binary, which reports 0 on Apple Silicon);
  the GPU card's "—°C" aside, which no helper key could ever fill, is gone.
- Render: `background.sheen` no longer keeps the display link running. The
  pointer highlight redraws on pointer moves over a sheened surface and
  once on exit; at rest that is zero frames.
- Popups: the pointer is sampled in the popup's own window, and no longer
  mirrored vertically, so the sheen highlight lights the row under the
  cursor.
- Animation: the display-link tick paints every surface directly, at the
  slowest hosted panel's refresh rate (60–120 Hz), so a 120 Hz built-in
  display next to a 60 Hz external one no longer blocks the main thread in
  `nextDrawable()`; damage is consumed where it is painted, and a tick
  retires any pending coalesced redraw.
- CI: `NSGlassEffectView.effectIsInteractive` is a macOS 27 SDK symbol, and
  `#available(macOS 27.0, *)` alone cannot hide it from a compiler whose
  SDK lacks it. Its three call sites are gated by `#if compiler(>=6.4)`,
  the way `compiler(>=6.2)` already tracks the macOS 26 SDK, so the
  macOS 26 runner builds again; the v0.2.0 release run died on this in its
  Test step, before the formula was pinned.

### Changed

- Usage errors from every local verb exit 2 — `ybar theme bogus` and a bare
  `ybar theme use` used to exit 1 — while a failed operation stays at 1.
- `--bar glass_variant` accepts `default` / `off` (restoring the built-in
  `clear`), the same tokens the item-level setter takes to drop a per-item
  override; both error messages list `clear|regular|default|off`.
- ninefiveb: `colors.lua`, `default.lua`, `settings.lua` and
  `helpers/default_font.lua` are no longer copies of the sketchybar-glass
  files; `ybarrc.lua` resolves them from `../sketchybar-glass` (or
  `~/.config/ybar/themes/sketchybar-glass`) and stops with an error naming
  both locations when neither exists, rather than falling through to the
  port's different palette and defaults.
- ysuite-liquid: the `padding_top` / `padding_bottom` keys its popup widgets
  set on some twenty-five items are dropped; the engine accepts and discards
  both, so nothing moves.
- Release workflow: a tag is refused unless this file has its
  `## [<version>]` section and SECURITY.md lists its `<major.minor>.x`
  series, and that section — read from the tag's own tree — becomes the
  GitHub Release notes.

### Removed

- The `dock`, `control_center` and `app_icons` glass variants. They were
  not `NSGlassEffectView` styles but magic numbers fed to the private
  `_setVariant:` selector, reverse-engineered from one OS build; `clear`
  and `regular` remain, mapped 1:1 onto the public styles, and the old
  names are rejected with the accepted list at both levels.
- The liquid-lens backdrop (the ScreenCaptureKit capture, the
  per-arrangement texture map and the refraction shader): nothing on any
  branch ever constructed it. Behaviour is unchanged.

### Docs

- README GIFs re-shot on ysuite-liquid, with placeholder network and device
  names.
- docs/WINDOWS-PORT.md synced three ways with the `windows` branch's copy:
  the port's process-control and console-ownership sections, the corrected
  `Uniforms` ABI paragraph, and wording that keeps
  `start`/`stop`/`restart`/`status` attributed to the unmerged
  `wip/process-control-cli` branch.
- docs/ARCHITECTURE.md's redraw policy describes the display-link pacing
  above.
- docs/EXTENDING.md catalogues the 0.2 surface: the Liquid Glass keys and
  `background.sheen`, item-level `x_offset`, the slider track ring, the
  bars graph keys and the four Wi-Fi verbs with their callback codes.
- README, VISION, SECURITY and ARCHITECTURE disclose the engine's one
  undocumented-ABI read — the `_isPersonalHotspot` ivar peek — in place of
  the "100% public APIs" claim.
- THIRD_PARTY.md credits the vendored Lua 5.4 interpreter (`Sources/CLua`,
  MIT) and the `windows` branch's copy and vcpkg dependencies.
- `themes/registry.json` carries rows for `ninefiveb` and `ysuite-liquid`.
- The example READMEs name the prerequisites the Liquid Glass themes
  inherit from the port (Symbols Nerd Font, `blueutil`, the `menus`
  helper), and docs/INSTALL.md says the Wi-Fi popup's scan and join wait on
  the Location grant.
- This changelog, from 0.1.0 on.

## [0.2.0] — 2026-09-22

Tagged at a3db0e8 but never published: the release workflow failed on the
GitHub runners (the SDK-27 symbol gating fixed above), so no GitHub Release
was cut and the Homebrew formula stayed pinned to 0.1.0. These changes ship
with the next release.

### Added

- Liquid Glass keys: `background.sheen` (a specular rim and a pointer
  highlight drawn in-shader), `glass_tint` (`--bar glass_tint` is inherited
  by every glass pill and overridable per item and per part) and
  `glass_variant` (bar- and item-level; at the tag both setters accepted
  `clear|regular|dock|control_center|app_icons` — the last three are removed
  under Unreleased above).
- Graph items: `graph.style=line|bars`, `graph.tick`, `graph.plot_width`,
  `graph.axis_max` and `graph.marks` (the battery chart's charging marks).
- Item-level `x_offset` (the background-level key already existed): slides
  the drawn pill without pushing the items that follow.
- Wi-Fi: `ybar.wifi_scan`, `ybar.wifi_join`, `ybar.wifi_prompt` and
  `ybar.wifi_disconnect`; a glass password window for locked networks that
  joins through `networksetup`'s stdin. Names stay redacted until the
  existing `--bar wifi_ssid_prompt=on` Location opt-in (a 0.1.0 key).
- Themes: `ysuite-liquid` (the ysuite-web "Liquid Glass on Metal" mock) and
  `ninefiveb` (the maintainer's daily driver); `sketchybar-glass` floats as
  an island on a glass strip.
- sketchybar-port: the Background popup drills into a background app's real
  menu and invokes its entries; a full now-playing media popup (artwork,
  seek, transport, volume); GPU utilization in the system monitor; hover
  feedback on pills and popup rows.
- `--volume <0-100|+N|-N>` and `ybar.volume()` set the output volume over
  CoreAudio in-process; `--query apps` and `--app <pid|bundle-id>
  activate|hide|quit|kill`, the permission-free app level.
- Built-in `ybar theme list|current|use|reset|install` and `ybar autostart
  enable|disable|status`; `--help` lists every verb; `--version` reports
  the bundle's build (the commit a `make app` or `--HEAD` install stamps).
- Bar `fullscreen_hide`; `popup.fade_in` / `popup.fade_out`;
  `slider.interactive=off` read-only meters; sliders inside popups;
  `icon.background.*` / `label.background.*` plates; `icon.shadow` /
  `label.shadow`; `background.shadow.blur`; `image.desaturate` /
  `image.y_offset`; `toggle` on every item boolean.
- `ybarrc.jsonc` / `ybar.jsonc` config entry points.
- CI on macOS 26 and 15 for every push to `main`; a tag-driven release
  workflow that pins the Homebrew formula from the tag's own tarball; the
  canonical tap (now NineFiveB/homebrew-ybar); SECURITY.md.
- The Windows port: docs/WINDOWS-PORT.md as the contract of record and the
  `windows` branch (win-v0.1.0), with its own GIFs in the README.

### Fixed

- IPC: the socket node is created owner-only, the instance lock is taken
  first, and a socket the daemon did not bind is never unlinked.
- Popups and tooltips are clamped into the host's screen and open on the
  display the host was clicked on; a hovered row is released when its panel
  goes away; a drag whose item was removed mid-drag heals.
- Trackpad scrolling steps per 10 pt instead of per sample.
- Providers: the media provider is armed on the first `media_change`
  subscription and publishes "stopped" when the player quits; the SSID is
  re-published once the Location grant lands; `idle_inhibit` keys the IOPM
  assertion off the held id; a missing Accessibility grant for
  `modifier_change` is reported once.
- Animation: a finished key is removed before its completion runs;
  `--remove` / `ybar.remove` cancel animations and drop Lua refs; marquee
  demand is accumulated across surfaces and popups.
- Render: no text-shadow copy for colour glyphs; per-part plates clip like
  their ink; a graph stroke stays inside its box and its border; the two
  silent no-render guards are reported and retried.
- Render: `background.padding_left` / `background.padding_right` widen the
  pill. Both keys were parsed and reported by `--query` since 0.1.0, but
  the renderer ignored them: the pill was always exactly the content box
  wide.
- Audio: `--volume +N` steps from the kept scalar, not the muted 0;
  `ybar.volume(n)` is clamped into 0–100; the CoreAudio listener blocks no
  longer capture `self`.
- JSONC: a rejected entry names its item and file; a non-string item
  position is rejected instead of defaulting to left.
- `item:query()` answers for its own item; `ybar theme` / `autostart`
  refusals point at a remedy that works; a recorded theme that shadows the
  user's own rc is reported.
- Script handlers: the child's process group is signalled, escalating to
  SIGKILL; the daemon's own directory leads the handlers' PATH.
- Homebrew: the v0.1.0 formula pinned the wrong tarball checksum (a stable
  install was broken).

### Docs

- README demo GIFs (bar and popups), a Windows section with its own GIFs,
  and the capability catalog moved to docs/EXTENDING.md.
- docs/ARCHITECTURE.md describes the tree as built; docs/VISION.md,
  docs/INSTALL.md and docs/THEMES.md realigned; a README for each flagship
  example theme; the repo-owned themes credited to NineFiveB in the
  registry.

## [0.1.0] — 2026-08-04

First tagged release.

[Unreleased]: https://github.com/NineFiveB/YBar/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/NineFiveB/YBar/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/NineFiveB/YBar/releases/tag/v0.1.0
