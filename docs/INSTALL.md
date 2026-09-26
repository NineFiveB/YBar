# Installing YBar

YBar is distributed as source: it has no Apple Developer ID, so a downloaded
binary would fail Gatekeeper. Building locally (Homebrew formula or `make app`)
produces a bundle with a fresh local signature that macOS accepts without
ceremony. All routes need macOS 14+ and a Swift 6 toolchain — the Command Line
Tools are sufficient, full Xcode is not required (see
[BUILDING.md](BUILDING.md)). Liquid Glass needs macOS 26 at runtime; on
macOS 14 and 15 the same themes draw a blur in its place. Windows users:
[WINDOWS.md](WINDOWS.md).

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
  identity, see [Permissions](#permissions))
- `ybar` on your PATH — the CLI: process control (`ybar start|stop|restart|
  status|autostart`), sketchybar-compatible messages, and `ybar --help`

Launch, and pick a look:

```sh
ybar start
ybar theme use darxk            # any name from `ybar theme list` (THEMES.md)
ybar autostart enable           # bring it back at every login (Autostart, below)
```

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
unzip YBar-0.2.1.zip -d ~/Applications
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
ybar start

# Manual build (from the clone) — nothing puts ybar on your PATH here:
cp examples/ybarrc.lua ~/.config/ybar/ybarrc.lua
make start          # or: ~/Applications/YBar.app/Contents/MacOS/ybar start
```

`ybar start` finds YBar.app and launches it in the background, because the
bundle is what gives the daemon its own privacy identity — running the bare
binary from a terminal does not. It looks for the bundle it is running from
first, then `~/Applications`, `/Applications`, then the Homebrew prefixes —
`$HOMEBREW_PREFIX` first when your shell exports it, then `/opt/homebrew` and
`/usr/local`. If none of those holds a bundle it falls back to whatever
LaunchServices has registered for `com.ybar.YBar`, which is how a copy
installed somewhere unusual is found. Pass `-c <path>` to name a config; with
no `-c` the discovery order at the top of this section applies. Once a login
job owns the bar ([Autostart](#autostart-launchagent)), `start` goes through
launchd instead — the job is kickstarted, or loaded again after a `stop` that
had to boot it out — so there is one supervised bar and never an unmanaged
copy beside it.

The rest of the process-control verbs:

```sh
ybar stop        # stop the running bar
ybar restart     # stop it and launch it again (a supervised bar: through launchd)
ybar status      # running or not, which bundle, which config, autostart state
```

`ybar --exit` still works and does the same thing as `ybar stop`; `stop` also
waits for the process to actually go, and tells you if a login agent will
bring it back. A bar that is alive but has stopped answering is reported as
such (`status` says `running (pid N) but not answering`), and `restart`
gives it 15 s to answer — a bar still booting looks the same — and then
replaces it. The escape hatch for a hung bar, when you would rather not go
through the verb, is `launchctl kickstart -k gui/$(id -u)/com.ybar.YBar` —
the same command `restart` reaches for. If the CLI is not on your PATH, every
verb works through the bundle too:
`~/Applications/YBar.app/Contents/MacOS/ybar status`.

`ybar --version` names the build — quote it in bug reports: `make app`,
`make release` and `brew install --HEAD` stamp the commit into the bundle
(`ybar 0.2.1 (a1b2c3d)`), a tagged Homebrew install reports the release
build number from the committed plist (`ybar 0.2.1 (3)`), and a binary
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
  YBar.app, then `ybar restart`. Closing popups by clicking outside them
  needs no permission.
- **Location (Wi-Fi network name)** — macOS gates the SSID behind Location
  Services. Opt in once with `ybar --bar wifi_ssid_prompt=on` and click
  Allow; the network name is re-published the moment the grant lands (no
  restart or `--trigger wifi_change` needed). Without it, wifi widgets show
  a generic connected state. The Wi-Fi popup's scan needs the same grant:
  until it lands CoreWLAN withholds every network name from the daemon
  (`ybar.wifi_scan` reports code 3 and the popup can only offer the opt-in
  above), so nothing can be joined from the popup until the grant lands.
  Joining a locked network you have not saved (`ybar.wifi_prompt`) raises
  YBar's own password panel — a key window of the daemon, not a system
  dialog, so no further grant; the password goes to `networksetup` and
  nowhere else.
- **Screen Recording** — needed by the `alias` component, which screenshots
  other apps' menu bar items via ScreenCaptureKit, and by
  `--bar refraction=screen`, which captures the strip behind the bar so the
  glass rim can refract it. macOS prompts on first capture; if you dismissed
  it, grant manually under Privacy & Security → Screen & System Audio
  Recording, then `ybar restart`. Nothing else in YBar asks for it, and
  `refraction` is `off` by default.

  `refraction=screen` is the only value that can raise the prompt. Because the
  bar runs as a LaunchAgent with no foreground window, the request registers
  YBar in that Settings pane rather than showing a sheet — enable it there and
  restart. Until then the mode falls back to `wallpaper`, and
  `ybar --query bar` reports which source is actually running:

  ```sh
  ybar --query bar | jq '{refraction, refraction_source, refraction_active}'
  # refraction        what you asked for
  # refraction_source what it resolved to (off|screen|wallpaper)
  # refraction_active whether a backdrop is live right now
  ```

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

Once the job is loaded, the process verbs go through launchd. `ybar restart`
asks the bar to quit and kickstarts the job — a bar that ignores the request,
or is alive and still silent after 15 s, is replaced with
`launchctl kickstart -k`, and a kickstarted job that has not come up after
launchd's 30 s throttle is kicked once more with `-k` and given 15 s more
before `restart` gives up and names the log. `ybar stop` sends `--exit` and
leaves the job loaded: `KeepAlive.SuccessfulExit = false` restarts YBar after
a crash (or a kill) but respects that clean exit. `ybar start` kickstarts a
stopped job. Never `pkill`: launchd reads a kill as a crash and brings the bar
straight back. The manual escape hatch for a hung bar is the same
`launchctl kickstart -k gui/$(id -u)/com.ybar.YBar`.

A hand-written plist with `<key>KeepAlive</key><true/>` relaunches after
*any* exit, a `--exit` included, so against one `ybar stop` boots the job out
instead and says so; `ybar status` shows the shape as `autostart: enabled (…,
KeepAlive: always)`. The plist stays, and `ybar start` or the next login loads
the job again. Re-run `ybar autostart enable` to rewrite it so a plain stop
holds, or `ybar autostart disable` to remove it.

`brew services start ybar` is deliberately not wired up. Two agents both set
to run at login race for the same socket, and the loser exits quietly enough
that launchd records it as a clean quit and never retries. `ybar status`
reports a Homebrew job when it sees one, and `ybar autostart enable` refuses
until you run `brew services stop ybar`.

macOS 13 and later list the agent under System Settings → General → Login
Items. Turning it off there leaves the plist on disk and records a persistent
override inside launchd instead, which survives reinstalling the plist and
reboots. `ybar autostart status` reports the override when it sees one, `ybar
start` launches an unmanaged bar for the session while it stands, and `ybar
autostart enable` is what clears it.

What `enable` writes, for reference — a hand-written copy works too,
substituting absolute paths (launchd does not expand `~`; Homebrew users:
point at `$(brew --prefix)/opt/ybar/YBar.app/...`). `-c <path>` joins
`ProgramArguments` only when a config was pinned:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>com.ybar.YBar</string>
	</array>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>Label</key>
	<string>com.ybar.YBar</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/you/Applications/YBar.app/Contents/MacOS/ybar</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StandardErrorPath</key>
	<string>/Users/you/Library/Logs/ybar.log</string>
	<key>ThrottleInterval</key>
	<integer>30</integer>
</dict>
</plist>
```

| Key | Value | Why |
|---|---|---|
| `ProgramArguments` | `…/YBar.app/Contents/MacOS/ybar`, plus `-c <path>` if you passed one to `enable` | absolute: launchd expands no `~` and inherits no working directory; the binary inside the bundle keeps the app's TCC identity |
| `RunAtLoad` | `true` | start it at login |
| `KeepAlive` | `SuccessfulExit = false` | restart after a crash, but respect a deliberate `ybar stop`, which exits cleanly |
| `ProcessType` | `Interactive` | exempt from the throttling launchd applies to background work |
| `LimitLoadToSessionType` | `Aqua` | the bar draws windows, so it needs a real GUI session |
| `AssociatedBundleIdentifiers` | `com.ybar.YBar` | System Settings' Login Items row reads "YBar", not a raw label |
| `ThrottleInterval` | `30` | a boot failure the daemon cannot recover from exits 1, and `KeepAlive` retries every non-zero code — this is what keeps that from becoming a respawn storm |
| `StandardErrorPath` | `~/Library/Logs/ybar.log` | a failure at login is otherwise invisible: the bar simply never appears. `start` and `restart` roll it past 1 MB and point at it when a kickstarted job does not come up |

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ybar.YBar.plist   # what enable runs
launchctl bootout gui/$(id -u)/com.ybar.YBar                                  # what disable runs
```
