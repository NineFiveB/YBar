# Installing YBar on macOS

Windows users want [the README's Windows section](../README.md#windows)
instead: that port ships Authenticode-signed binaries, a one-line PowerShell
installer and a Scoop manifest, and nothing on this page applies to it.

On macOS YBar is distributed as source: it has no Apple Developer ID, so a
downloaded binary would fail Gatekeeper. Building locally (Homebrew formula or `make app`)
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
  identity, see [Permissions](#permissions))
- `ybar` on your PATH — the CLI: process control (`ybar start|stop|restart|
  status|autostart`), sketchybar-compatible messages, and `ybar --help`

Launch:

```sh
ybar start
```

Heed the formula's caveats: upgrades re-sign the app, which voids previously
granted permissions unless you re-sign with a stable local certificate (see
[Keeping permissions across rebuilds](#keeping-permissions-across-rebuilds)).

## Release zip

(Applies once a tagged release with an attached zip exists on GitHub.)

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

YBar looks for a config at `~/.config/ybar/ybarrc.lua` (also `ybarrc`,
`~/.ybarrc.lua`, `~/.ybarrc`), or takes an explicit path via `-c`. A theme
selected with `ybar-theme use` is recorded in `~/.config/ybar/current-theme`
and outranks all of those when no `-c` is given. Start from
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
installed somewhere unusual is found.
Pass `-c <path>` to name a config; with no `-c` the discovery order at the top
of this section applies, and the theme recorded by `ybar-theme use` wins over
the plain `ybarrc.lua`.

The rest of the process-control verbs:

```sh
ybar stop        # stop the running bar
ybar restart     # stop it and launch it again
ybar status      # running or not, which bundle, which config, autostart state
```

`ybar --exit` still works and does the same thing as `ybar stop`; `stop` also
waits for the process to actually go, and tells you if a login agent will
bring it back. If the CLI is not on your PATH, every verb works through the
bundle too: `~/Applications/YBar.app/Contents/MacOS/ybar status`.

### Permissions

All prompts and grants attribute to **com.ybar.YBar** — you will see "YBar" in
System Settings, never your terminal. Grants cover the daemon and every helper
script it spawns. Only the features you actually configure ask for anything:

- **Bluetooth** — used by widgets that list/control devices. macOS prompts on
  first use; click Allow.
- **Calendar** — used by the calendar popup. Prompts on first use.
- **Accessibility** — needed for `modifier_change` events (live ⌥-held UX) and
  closing popups when you click outside them. macOS does not prompt for this:
  grant it manually under System Settings → Privacy & Security →
  Accessibility → **+** → select YBar.app, then `ybar restart`.
- **Location (Wi-Fi network name)** — macOS gates the SSID behind Location
  Services. Opt in once with `ybar --bar wifi_ssid_prompt=on` and click
  Allow; without it, wifi widgets show a generic connected state.
- **Screen Recording** — needed by the `alias` component, which screenshots
  other apps' menu bar items via ScreenCaptureKit. macOS prompts on first
  capture; if you dismissed it, grant manually under Privacy & Security →
  Screen & System Audio Recording, then `ybar restart`.
- **Automation (Apple Events)** — used to script Music and Spotify: the media
  provider seeds now-playing state at startup from a player that is already
  running, and the example configs send play/pause the same way. macOS prompts
  the first time YBar scripts each app; click OK. Denied, the startup seed
  silently finds nothing and the media widget stays empty until the player's
  next state change.

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

## Autostart

```sh
ybar autostart enable    # come up at every login, and after a crash
ybar autostart status    # where the login job is and what it runs
ybar autostart disable   # stop coming up at login
```

`enable` writes `~/Library/LaunchAgents/com.ybar.YBar.plist` and loads it
immediately, so it takes effect without logging out. The job runs the binary
*inside* the app bundle, which is what keeps the daemon's privacy identity. A
bar that was already running is handed over to launchd rather than left racing
it, so there is one supervised copy and no second one fighting for the socket.

`disable` boots the job out, removes the plist, and puts the bar back up
unmanaged — turning autostart off does not take your bar away.

What the agent contains:

| Key | Value | Why |
|---|---|---|
| `ProgramArguments` | `…/YBar.app/Contents/MacOS/ybar`, plus `-c <path>` if you passed one to `enable` | absolute: launchd expands no `~` and inherits no working directory |
| `RunAtLoad` | `true` | start it at login |
| `KeepAlive` | `SuccessfulExit = false` | restart after a crash, but respect a deliberate `ybar stop`, which exits cleanly |
| `ProcessType` | `Interactive` | exempt from the throttling launchd applies to background work |
| `LimitLoadToSessionType` | `Aqua` | the bar draws windows, so it needs a real GUI session |
| `AssociatedBundleIdentifiers` | `com.ybar.YBar` | System Settings' Login Items row reads "YBar", not a raw label |
| `ThrottleInterval` | `30` | a boot failure the daemon cannot recover from exits 1, and `KeepAlive` retries every non-zero code — this is what keeps that from becoming a respawn storm |
| `StandardErrorPath` | `~/Library/Logs/ybar.log` | a failure at login is otherwise invisible: the bar simply never appears |

With no `-c`, the job leaves config discovery alone, so `ybar-theme use` keeps
working across logins — switch themes and the next login comes up in the new
one. Pass `ybar autostart enable -c <path>` to pin one config instead.

`brew services start ybar` is deliberately not implemented. Two agents both set
to run at login race for the same socket, and the loser exits quietly enough
that launchd records it as a clean quit and never retries. If you have one from
somewhere else, `ybar status` reports the collision and `ybar autostart enable`
refuses until you run `brew services stop ybar`.

Two things worth knowing:

- YBar is ad-hoc signed, so every rebuild or `brew upgrade` changes its
  signature. macOS cannot tell the new copy is the same app, which re-prompts
  for privacy grants and resets its Login Items approval. A stable local
  certificate fixes it — see
  [Keeping permissions across rebuilds](#keeping-permissions-across-rebuilds).
- macOS 13 and later list the agent under System Settings → General → Login
  Items. Turning it off there leaves the plist on disk and records a persistent
  override inside launchd instead, which survives reinstalling the plist and
  reboots. `ybar autostart status` reports the override when it sees one, and
  `ybar autostart enable` is what clears it.

The plist is a normal file: `ybar autostart status` prints its path, and you
can hand-edit it — though re-running `ybar autostart enable` overwrites it.
Reload an edited one with

```sh
launchctl bootout gui/$(id -u)/com.ybar.YBar
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ybar.YBar.plist
```

which is also the manual route if you would rather not use the verb at all.
