# YBar + yabai + skhd

Drop-in configs for running YBar with [yabai](https://github.com/koekeishiya/yabai)
and [skhd](https://github.com/koekeishiya/skhd).

The example config's workspace pills auto-detect the window manager: the
one actually running wins (yabai and AeroSpace can coexist installed side
by side), and if neither is running the choice falls back to whichever is
installed. The yabai adapter (`items/spaces_yabai.lua`) drives native
macOS Spaces.

## Files

- **`yabairc`** — signal recipes that push space/window changes to the bar
  instantly. Without them the adapter still works from NSWorkspace space
  events plus a 5-second poll; with them, window creates/destroys/minimizes
  repaint immediately. The `ybar` CLI folds every `$YABAI_*` signal variable
  into the trigger's env automatically.
- **`skhdrc`** — mode declarations that drive the bar's mode indicator pill
  (`widgets.skhd_mode`, hidden in default mode), plus a common yabai
  binding starter set.

Any skhd binding can drive the bar directly: `ybar --trigger <event>
KEY=value`, `ybar --set <item> ...`, `ybar --bar hidden=toggle` — the full
CLI surface is available from hotkeys.

## What needs the scripting addition (and what doesn't)

yabai's feature set splits in two: most of it uses public APIs, but a set
of commands only works through the scripting addition (SA) — code yabai
injects into Dock.app, which requires partially disabling System Integrity
Protection. Without the SA those commands are silent no-ops: no error
message, nothing happens.

Works **without** the SA (verified on macOS 26/27):

- Window focus, warp, resize
- Moving a window **to** another space (`yabai -m window --space <n>`)
- Float toggle, minimize
- All YBar bar updates — the signals in `yabairc` and the spaces adapter
  need no SA at all

**Requires** the SA (these are the commands `man yabai` marks "System
Integrity Protection must be partially disabled"):

- `space --focus`, `space --create`, `space --destroy`, `space --switch`
- `space --display` (moving a space between displays)
- `window --toggle sticky|pip|shadow`
- Window sub-layer, opacity, raise/lower

The bar itself is fully functional either way; the SA only decides which
skhd bindings do anything.

## Enabling the scripting addition on macOS 26/27

Two steps, and on Apple Silicon you need **both**:

1. Partially disable SIP from Recovery (on Apple Silicon: hold the power
   button at boot, then Options → Utilities → Terminal):

   ```
   csrutil enable --without fs --without debug --without nvram
   ```

2. On Apple Silicon, additionally set the preview-ABI boot argument (from
   normal macOS, after step 1 — SIP's NVRAM protection must already be off
   for this write to stick), then reboot:

   ```
   sudo nvram boot-args="-arm64e_preview_abi"
   ```

   This boot-arg is the step people most often miss: with SIP partially
   disabled but no boot-arg, the SA still fails to load.

After the reboot, load the SA with `sudo yabai --load-sa` (the yabai wiki
documents the sudoers rule that lets yabai reload it automatically on
restart).

**Beta caveat:** the SA injects into Dock.app at memory offsets derived
per macOS build, so a macOS update — beta builds especially — can break it
until offsets for the new build exist. If the SA stops loading after an
update, check the upstream yabai repository's issue tracker for your build
number; community forks sometimes carry offsets for beta builds before
they land upstream.

## Verify your setup

```
yabai -m query --spaces        # lists spaces → yabai is running and answering
yabai -m space --focus 2       # actually switches → the SA is live
```

The first command only proves yabai's server is up. The second is the
practical SA test: if the space visibly switches, everything SA-gated
above works; if nothing happens, revisit the two steps in the previous
section (the boot-arg first).

For the bar side: switch spaces or open/close a window — with the
`yabairc` signals registered, the pills repaint instantly instead of
waiting for the next poll.
