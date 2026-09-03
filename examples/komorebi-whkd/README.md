# komorebi + whkd pairing

Replaces the macOS yabai-skhd example. Nothing has to be added to
komorebi.json or whkdrc for the bar to work: ybar detects komorebi on its
own (re-checked once per second, so start order does not matter), subscribes
to its socket, and — with `--bar reserve=komorebi`, which is what the default
`auto` resolves to whenever komorebi is detected — sends
`MonitorWorkAreaOffset` for every monitor itself. Spec section 11.6.

## komorebi.json

Do NOT also set `global_work_area_offset` (or a per-monitor
`work_area_offset`) for the bar strip: ybar sends the offset itself and
zeroes it again on `ybar --exit`, so a static one reserves the strip twice.

## whkdrc

whkd runs each binding through the shell named by its `.shell` line, so keep
`ybar` bindings to plain `key=value` tokens — JSON in single quotes survives
`pwsh` but not `cmd` or Windows PowerShell:

    alt + 1         : komorebic focus-workspace 0
    alt + 2         : komorebic focus-workspace 1
    alt + b         : ybar --bar hidden=toggle
    alt + shift + r : ybar --trigger komorebi_workspace_change

The last one is the forced re-query: the daemon re-reads live komorebi state
and replays `komorebi_workspace_change` — the same boot-population idiom the
`sketchybar-glass` workspace strip uses at load. `ybar --komorebi '<json>'`
(a raw `SocketMessage` written straight to `komorebi.sock`, no `komorebic`
spawn) is the click-script form: theme `click_script`s run through the
daemon's resolved POSIX shell (spec 10.1), where that quoting is safe.

## Pairing walkthrough

1. Start komorebi and whkd as you normally do.
2. `ybar theme use catppuccin-komorebi` (its bar sets `reserve: komorebi` and
   its workspace pill subscribes to `komorebi_workspace_change`), then `ybar`.
3. Switch workspaces from whkd: the pill follows `FOCUSED_WORKSPACE`
   (`WORKSPACES` and `FOCUSED_WORKSPACE_INDEX` carry the full strip), and
   tiled windows stop below the bar instead of underneath it.
