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
- `ybar` on your PATH — the CLI client (`ybar --help`, sketchybar-compatible
  messages)

Launch:

```sh
open -g "$(brew --prefix)/opt/ybar/YBar.app" --args -c ~/.config/ybar/ybarrc.lua
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
`~/.ybarrc.lua`, `~/.ybarrc`), or takes an explicit path via `-c`. Start from
an example — Homebrew installs them under `$(brew --prefix)/share/ybar/examples`,
a git clone has them in `examples/`:

```sh
mkdir -p ~/.config/ybar
# Homebrew install:
cp "$(brew --prefix)/share/ybar/examples/ybarrc.lua" ~/.config/ybar/ybarrc.lua
open -g "$(brew --prefix)/opt/ybar/YBar.app" --args -c ~/.config/ybar/ybarrc.lua
# Manual build (from the clone):
cp examples/ybarrc.lua ~/.config/ybar/ybarrc.lua
open -g ~/Applications/YBar.app --args -c ~/.config/ybar/ybarrc.lua
```

Always launch through the app bundle (`open -g … --args …`), not the bare
binary from a terminal: the bundle is what gives the daemon its own privacy
identity. Stop it with `ybar --exit`
(`~/Applications/YBar.app/Contents/MacOS/ybar --exit` if the CLI is not on
your PATH).

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
  Accessibility → **+** → select YBar.app, then restart YBar (`ybar --exit`
  and relaunch).
- **Location (Wi-Fi network name)** — macOS gates the SSID behind Location
  Services. Opt in once with `ybar --bar wifi_ssid_prompt=on` and click
  Allow; without it, wifi widgets show a generic connected state.
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

Save as `~/Library/LaunchAgents/com.ybar.YBar.plist`, substituting absolute
paths (launchd does not expand `~`; Homebrew users: point at
`$(brew --prefix)/opt/ybar/YBar.app/...`). Running the binary inside the
bundle keeps the app's TCC identity:

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
        <string>-c</string>
        <string>/Users/you/.config/ybar/ybarrc.lua</string>
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
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ybar.YBar.plist
```

`KeepAlive.SuccessfulExit = false` restarts YBar after a crash but respects a
deliberate `ybar --exit`. To unload:

```sh
launchctl bootout gui/$(id -u)/com.ybar.YBar
```
