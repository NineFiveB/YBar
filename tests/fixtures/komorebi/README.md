# komorebi protocol fixtures

Recorded against komorebi **v0.1.41** (tag `v0.1.41`, released 2026-05-03)
over the live socket protocol (spec 11.1/11.2): a listener socket created in
`%LOCALAPPDATA%\komorebi`, registered exactly as `KomorebiProvider` does —

```json
{"type":"AddSubscriberSocketWithOptions","content":["ybar-fixture.sock",{"filter_state_changes":true}]}
```

— each notification captured as one accept → read-to-EOF JSON document, the
State reply captured from a `{"type":"State"}` query on `komorebi.sock`.

## Recorded

- `state.json` — full State reply: 1 monitor (`monitors.focused` = 0,
  `device_id` `SDC419C-5&292e6c21&0&UID4353`), 7 workspaces named I..VII,
  one managed `chrome.exe` window. The window title was sanitized after
  recording; everything else is as received.
- `notification-add-subscriber.json` — the Socket
  `AddSubscriberSocketWithOptions` notification komorebi echoes when the
  subscription registers (tuple content: name + options).
- `notification-toggle-pause-on.json` / `notification-toggle-pause-off.json`
  — Socket `TogglePause` (unit variant, no `content` key);
  `state.is_paused` flips true/false between the two.

## Synthetic

`synthetic-*.json` are hand-written to the spec 11.2 schema, NOT recorded —
shapes a single-monitor recording session could not produce:

- `synthetic-focus-change.json` — adjacently tagged `WindowManagerEvent`
  `FocusChange` with the `(WinEvent, Window)` tuple content.
- `synthetic-virtual-desktop.json` — `VirtualDesktopNotification`, whose
  untagged unit variants serialize `event` as a bare string.
- `synthetic-tolerance.json` — unknown fields at every level plus missing
  optionals (`focused` keys absent, workspace `name` null or absent).

Re-record against the current komorebi when the `komorebi-canary` CI job
trips.
