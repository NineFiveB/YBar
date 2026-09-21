# Installing YBar

YBar is distributed as source: it has no Apple Developer ID, so a downloaded
binary would fail Gatekeeper. Building locally (Homebrew formula or `make app`)
produces a bundle with a fresh local signature that macOS accepts without
ceremony. All routes need macOS 14+ and a Swift 6 toolchain — the Command Line
Tools are sufficient, full Xcode is not required (see
[BUILDING.md](BUILDING.md)).

## Homebrew (recommended)

```sh
brew tap NineFiveB/ybar            # github.com/NineFiveB/homebrew-ybar
brew install ybar               # latest tagged release
# or:
brew install --HEAD ybar        # build from current main
```

Recent Homebrew asks you to confirm trusting a third-party tap the first
time you install from it; `brew trust NineFiveB/ybar` pre-approves it (useful
in scripts, where the prompt would fail instead). Tapping the main repo
directly also works: `brew tap NineFiveB/ybar https://github.com/NineFiveB/YBar.git`.

This builds YBar from source and installs:

- `$(brew --prefix)/opt/ybar/YBar.app` — the app bundle (the daemon's TCC
  identity, see [Permissions](#first-run-permissions))
- `ybar` on your PATH — the CLI: process control (`ybar start|stop|restart|
  status`), local verbs (`ybar theme …`, `ybar autostart …`), and
  sketchybar-compatible messages (`ybar --help`)

Launch:

```sh
ybar start
# or with an explicit config:
ybar start -c ~/.config/ybar/ybarrc.lua
```

`ybar start` finds YBar.app and launches it in the background so privacy
prompts attribute to YBar rather than your terminal. `ybar status` /
`ybar stop` / `ybar restart` manage that bar.

Heed the formula's caveats: upgrades re-sign the app, which voids previously
granted permissions unless you re-sign with a stable local certificate (see
[Keeping permissions across rebuilds](#keeping-permissions-across-rebuilds)).

## Release zip

(Prospective: the release workflow deliberately publishes source only — no
release carries a zip today. This route applies if one ever does.)

Each tagged release ships `YBar-<version>.zip` (built by `make release`). The
signature inside is the maintainer's local certificate — your Mac does not
trust it, and the download carries quarantine, so Gatekeeper will refuse the
app as-is. Strip quarantine and re-sign locally:

```sh
unzip YBar-0.1.0.zip -d ~/Applications
xattr -dr com.apple.quarantine ~/Applications/YBar.app
codesign --force --sign - --identifier com.ybar.YBar ~/Applications/YBar.app
```

## Manual build

```sh
git clone https://github.com/NineFiveB/YBar.git
cd YBar
make app
```

Produces `~/Applications/YBar.app`, signed with the local "YBar Signing"
certificate if one exists, ad-hoc otherwise. If the clone lives under an
iCloud-synced directory, the Makefile's scratch path already handles the
codesign/xattr race — details in [BUILDING.md](BUILDING.md).

## First run

YBar takes an explicit path via `-c`; otherwise it starts the theme selected
with `ybar theme use` ([THEMES.md](THEMES.md)), and failing that looks for a
config at `~/.config/ybar/ybarrc.lua` (also `ybarrc`, `ybarrc.jsonc`,
`ybar.jsonc`, then `~/.ybarrc.lua`, `~/.ybarrc`). Start from
an example — Homebrew installs them under `$(brew --prefix)/share/ybar/examples`,
a git clone has them in `examples/`:

```sh
mkdir -p ~/.config/ybar
# Homebrew install:
cp "$(brew --prefix)/share/ybar/examples/ybarrc.lua" ~/.config/ybar/ybarrc.lua
ybar start -c ~/.config/ybar/ybarrc.lua
# Manual build (from the clone):
cp examples/ybarrc.lua ~/.config/ybar/ybarrc.lua
ybar start -c ~/.config/ybar/ybarrc.lua
# or: make start
```

Always launch through `ybar start` (or the app bundle), not a bare
`swift run` binary from a terminal: the bundle is what gives the daemon its
own privacy identity. Stop it with `ybar stop` (or `ybar --exit` against a
running daemon).

`ybar --version` names the build — quote it in bug reports: `make app`,
`make release` and `brew install --HEAD` stamp the commit into the bundle
(`ybar 0.1.0 (a1b2c3d)`), a tagged Homebrew install reports the release
build number from the committed plist (`ybar 0.1.0 (1)`), and a binary
outside a bundle prints the bare version.

### Permissions

All prompts and grants attribute to **com.ybar.YBar** — you will see "YBar" in
System Settings, never your terminal. Grants cover the daemon and every helper
script it spawns. Only the features you actually configure ask for anything:

- **Bluetooth** — used by widgets that list/control devices. macOS prompts on
  first use; click Allow.
- **Calendar** — used by the calendar popup. Prompts on first use.
- **Automation (Music, Spotify)** — the first `media_change` subscription
  seeds the now-playing state from a player that is already running by asking
  it over AppleScript (`osascript`), so with Music or Spotify open, macOS
  prompts "YBar wants access to control Music"; click OK. The query is given
  60 s, so a prompt left unanswered does not wedge the daemon. Deny it and the
  bar still follows the player's own change notifications from the next track
  on — only the state at startup is missed.
- **Accessibility** — needed for `modifier_change` events (live ⌥-held UX;
  without the grant modifier keys are only seen while the pointer is over the
  bar, and the daemon logs a one-time warning to stderr when a config
  subscribes to the event) and for `alias` items to forward clicks to the menu
  bar item they mirror. macOS does not prompt for the event monitor and may
  prompt on the first forwarded click; otherwise grant it manually under
  System Settings → Privacy & Security → Accessibility → **+** → select
  YBar.app, then restart YBar (`ybar restart`). Closing popups by
  clicking outside them needs no permission.
- **Location (Wi-Fi network name)** — macOS gates the SSID behind Location
  Services. Opt in once with `ybar --bar wifi_ssid_prompt=on` and click
  Allow; the network name is re-published the moment the grant lands (no
  restart or `--trigger wifi_change` needed). Without it, wifi widgets show
  a generic connected state.
- **Screen Recording** — needed by the `alias` component, which screenshots
  other apps' menu bar items via ScreenCaptureKit. macOS prompts on first
  capture; if you dismissed it, grant manually under Privacy & Security →
  Screen & System Audio Recording, then restart YBar.

### Keeping permissions across rebuilds

macOS keys TCC grants to the app's code signature. Ad-hoc signatures change on
every rebuild/upgrade, so Accessibility and Screen Recording must be re-granted
each time. A stable self-signed certificate fixes this:

1. Keychain Access → Certificate Assistant → Create a Certificate…
2. Name: `YBar Signing`, Identity Type: Self-Signed Root, Certificate Type:
   **Code Signing**.

`make app` picks the certificate up automatically. For Homebrew installs,
re-sign after each upgrade:

```sh
codesign --force --sign "YBar Signing" --identifier com.ybar.YBar \
  "$(brew --prefix)/opt/ybar/YBar.app"
```

## Autostart (LaunchAgent)

`ybar autostart enable` writes `~/Library/LaunchAgents/com.ybar.YBar.plist`
and bootstraps it; a daemon you started by hand is first asked to `--exit`
and handed over, so the agent's copy does not lose the instance lock to it:

```sh
ybar autostart enable                                 # config discovered at every start
ybar autostart enable -c ~/.config/ybar/ybarrc.lua    # or pin one
ybar autostart status
ybar autostart disable                                # bootout + remove the plist
```

Run it from the `ybar` inside YBar.app (Homebrew's `bin/ybar` resolves into
the keg and is rewritten to the stable `$(brew --prefix)/opt/ybar` path):
the agent runs that bundle binary, which keeps the app's TCC identity, and a
bare `swift build` product is refused. Without `-c`, the config is
discovered on every respawn — the theme selected with `ybar theme use`
first, then `~/.config/ybar` — which is what makes a theme switch survive a
restart; `enable` refuses when nothing is discoverable rather than write an
agent with nothing to start. With `-c`, that file wins on every restart even
after `ybar theme use` has reloaded the running bar.

Restart a supervised bar with
`launchctl kickstart -k gui/$(id -u)/com.ybar.YBar`, never `pkill`:
`KeepAlive.SuccessfulExit = false` restarts YBar after a crash (or a kill)
but respects a deliberate `ybar --exit`.

What `enable` writes, for reference — a hand-written copy works too,
substituting absolute paths (launchd does not expand `~`; Homebrew users:
point at `$(brew --prefix)/opt/ybar/YBar.app/...`). `-c <path>` joins
`ProgramArguments` only when a config was pinned:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.ybar.YBar</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/you/Applications/YBar.app/Contents/MacOS/ybar</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
```

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ybar.YBar.plist   # what enable runs
launchctl bootout gui/$(id -u)/com.ybar.YBar                                  # what disable runs
```
