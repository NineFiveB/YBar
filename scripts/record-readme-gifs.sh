#!/bin/bash
# Record README demo GIFs: wallpaper only, placeholder names (obfuscation, not redaction).
#
# This is the maintainer's recipe rather than a general tool: it drives the
# RUNNING bar over its socket (it never launches one), parks the recording on
# an empty AeroSpace workspace so only the wallpaper is in frame, and crops the
# capture at offsets measured on a 3024-wide retina display. Another setup
# keeps the sequence and changes the workspace numbers and the crop geometry
# below. Needs aerospace, ffmpeg and gifski on PATH; the bar is found through
# $YBAR, then `ybar` on PATH, then the app bundle under ~/Applications.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$repo/docs/media}"
Y="${YBAR:-$(command -v ybar || echo "$HOME/Applications/YBar.app/Contents/MacOS/ybar")}"
WORK="${TMPDIR:-/tmp}/ybar-gif-$$"
FFMPEG="$(command -v ffmpeg)" || { echo "[gif] ffmpeg not found on PATH (brew install ffmpeg)" >&2; exit 1; }
GIFSKI="$(command -v gifski)" || { echo "[gif] gifski not found on PATH (brew install gifski)" >&2; exit 1; }
mkdir -p "$WORK" "$OUT"
# Empty AeroSpace workspace so no app window is in frame.
EMPTY_WS="${YBAR_GIF_WORKSPACE:-8}"
RESTORE_WS="${YBAR_GIF_RESTORE:-2}"

log() { printf '[gif] %s\n' "$*"; }

# ── Pointer control ─────────────────────────────────────────────────────────
# The popups answer to real pointer events and nothing else: the hovered-day
# readout, the chart scrub and month paging come from mouse.entered,
# graph.hovered and mouse.scrolled, none of which the socket can fake. So the
# recording drives the actual cursor — which screencapture -v records, so the
# GIF shows what a viewer would be doing. swiftc ships with the Command Line
# Tools; without it the pointer segments are skipped and the popups still open.
POINTER=""
if command -v swiftc >/dev/null 2>&1; then
  cat > "$WORK/pointer.swift" <<'SWIFT'
import CoreGraphics
import Foundation
let a = CommandLine.arguments
guard a.count >= 3, let x = Double(a[1]), let y = Double(a[2]) else { exit(2) }
let p = CGPoint(x: x, y: y)
CGWarpMouseCursorPosition(p)
CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
if a.count > 3, a[3] == "click" {
    usleep(120_000)
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type,
                mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
    }
}
SWIFT
  swiftc -O "$WORK/pointer.swift" -o "$WORK/pointer" 2>/dev/null && POINTER="$WORK/pointer"
fi
[ -n "$POINTER" ] || log "swiftc not found: recording popups without the pointer segments"

at()  { [ -n "$POINTER" ] && "$POINTER" "$1" "$2" || true; }
tap() { [ -n "$POINTER" ] && "$POINTER" "$1" "$2" click || true; }
# A cursor that teleports reads as a glitch; step it so the eye can follow.
glide() {
  local x1=$1 y1=$2 x2=$3 y2=$4 steps=${5:-14} pause=${6:-0.03} i
  [ -n "$POINTER" ] || return 0
  for i in $(seq 1 "$steps"); do
    at $(( x1 + (x2 - x1) * i / steps )) $(( y1 + (y2 - y1) * i / steps ))
    sleep "$pause"
  done
}

# Pill centres come from the running bar, not from constants: the strip
# reflows whenever a widget appears or a pill changes size.
centre_of() {
  $Y --query "$1" 2>/dev/null | python3 -c 'import sys, json
r = json.load(sys.stdin).get("bounding_rects", {}).get("display-1")
print("%d %d" % (r["origin"][0] + r["size"][0] // 2, r["size"][1] // 2) if r else "0 0")'
}
right_of() {
  $Y --query "$1" 2>/dev/null | python3 -c 'import sys, json
r = json.load(sys.stdin).get("bounding_rects", {}).get("display-1")
print(r["origin"][0] + r["size"][0] if r else 0)'
}

close_popups() {
  $Y --set widgets.wifi.bracket popup.drawing=off 2>/dev/null || true
  $Y --set widgets.bluetooth.bracket popup.drawing=off 2>/dev/null || true
  $Y --set widgets.cpu.bracket popup.drawing=off 2>/dev/null || true
  $Y --set widgets.battery.bracket popup.drawing=off 2>/dev/null || true
  $Y --set widgets.menubar.bracket popup.drawing=off 2>/dev/null || true
  $Y --set widgets.media.bracket popup.drawing=off 2>/dev/null || true
  $Y --set calendar.bracket popup.drawing=off 2>/dev/null || true
  $Y --set calendar popup.drawing=off 2>/dev/null || true
}

# Placeholder names only. The liquid popup splits each network into
# name/button/lock/signal; the port theme is still one item per row.
paint_wifi() {
  if $Y --query widgets.wifi.known.1.name >/dev/null 2>&1; then
    local i
    for i in 1 2 3; do
      $Y --set "widgets.wifi.hotspot.$i.name" drawing=off width=0
      $Y --set "widgets.wifi.hotspot.$i.button" drawing=off width=0
      $Y --set "widgets.wifi.hotspot.$i.lock" drawing=off width=0
      $Y --set "widgets.wifi.hotspot.$i.signal" drawing=off width=0
    done
    $Y --set widgets.wifi.known.1.name drawing=on icon="Home Network"
    for i in 2 3 4 5 6; do
      $Y --set "widgets.wifi.known.$i.name" drawing=off width=0
      $Y --set "widgets.wifi.known.$i.button" drawing=off width=0
      $Y --set "widgets.wifi.known.$i.lock" drawing=off width=0
      $Y --set "widgets.wifi.known.$i.signal" drawing=off width=0
    done
    local names=("Coffee Shop" "Library-Guest" "Neighbor-5G" "CityMesh")
    i=1
    for name in "${names[@]}"; do
      $Y --set "widgets.wifi.other.$i.name" drawing=on icon="$name"
      i=$((i + 1))
    done
    for i in 5 6; do
      $Y --set "widgets.wifi.other.$i.name" drawing=off width=0
      $Y --set "widgets.wifi.other.$i.button" drawing=off width=0
      $Y --set "widgets.wifi.other.$i.lock" drawing=off width=0
      $Y --set "widgets.wifi.other.$i.signal" drawing=off width=0
    done
    $Y --set widgets.wifi.scan icon="Other networks" drawing=on
    return
  fi
  $Y --set compat.item.73 icon="Home Network" label="󰌾  󰖩" drawing=on
  $Y --set compat.item.74 icon="•" label="Connected" label.color=0xff30d158 drawing=on
  $Y --set widgets.wifi.known.1 drawing=on icon="✓  Home Network" icon.color=0xffffffff \
    label="󰤨" label.color=0xffffffff
  $Y --set widgets.wifi.known.2 drawing=off
  $Y --set widgets.wifi.known.3 drawing=off
  $Y --set widgets.wifi.known.4 drawing=off
  local names=("Coffee Shop" "Library-Guest" "Neighbor-5G" "CityMesh")
  local i=1
  for name in "${names[@]}"; do
    $Y --set "widgets.wifi.net.$i" drawing=on icon="$name" icon.color=0xff8e8e8e label="󰤨"
    i=$((i + 1))
  done
  for i in 5 6 7 8; do
    $Y --set "widgets.wifi.net.$i" drawing=off
  done
  $Y --set compat.item.78 icon="Travel VPN" label="Not Connected" drawing=on
}

paint_bluetooth() {
  # Liquid rows put the device name in the icon. The port uses the label
  # plus a separate status row.
  if $Y --query widgets.bluetooth.dev.1 >/dev/null 2>&1 \
      && ! $Y --query widgets.bluetooth.devstatus.1 >/dev/null 2>&1; then
    $Y --set widgets.bluetooth.dev.1 drawing=on icon="AirPods Pro"
    $Y --set widgets.bluetooth.dev.2 drawing=on icon="Magic Keyboard"
    $Y --set widgets.bluetooth.dev.3 drawing=on icon="Desk Speaker"
    # The glyph is its own item and is picked from the REAL device name, which
    # these placeholders never pass through — set it to match what is shown.
    $Y --set widgets.bluetooth.dev.1.icon drawing=on icon="sf:airpods.pro"
    $Y --set widgets.bluetooth.dev.2.icon drawing=on icon="sf:keyboard"
    $Y --set widgets.bluetooth.dev.3.icon drawing=on icon="sf:homepod"
    local i
    for i in 4 5 6; do
      $Y --set "widgets.bluetooth.dev.$i" drawing=off
      $Y --set "widgets.bluetooth.dev.$i.icon" drawing=off
    done
    $Y --set widgets.bluetooth.near.1 drawing=on icon="Pixel Buds"
    $Y --set widgets.bluetooth.near.2 drawing=on icon="MX Master"
    $Y --set widgets.bluetooth.near.1.icon drawing=on icon="sf:airpods"
    $Y --set widgets.bluetooth.near.2.icon drawing=on icon="sf:magicmouse"
    for i in 3 4 5 6; do
      $Y --set "widgets.bluetooth.near.$i" drawing=off
      $Y --set "widgets.bluetooth.near.$i.icon" drawing=off
    done
    return
  fi
  $Y --set widgets.bluetooth.dev.1 drawing=on label="AirPods Pro"
  $Y --set widgets.bluetooth.devstatus.1 drawing=on \
    icon="Connected · 72%" icon.color=0xff30d158
  $Y --set widgets.bluetooth.dev.2 drawing=on label="Magic Keyboard"
  $Y --set widgets.bluetooth.devstatus.2 drawing=on \
    icon="Not Connected" icon.color=0xff8e8e8e
  $Y --set widgets.bluetooth.dev.3 drawing=on label="Desk Speaker"
  $Y --set widgets.bluetooth.devstatus.3 drawing=on \
    icon="Not Connected" icon.color=0xff8e8e8e
  for i in 4 5 6; do
    $Y --set "widgets.bluetooth.dev.$i" drawing=off
    $Y --set "widgets.bluetooth.devstatus.$i" drawing=off
  done
  $Y --set widgets.bluetooth.near.1 drawing=on label="Pixel Buds"
  $Y --set widgets.bluetooth.near.2 drawing=on label="MX Master"
  for i in 3 4 5 6; do
    $Y --set "widgets.bluetooth.near.$i" drawing=off
  done
}

# Menu-bar extras are real background apps. Placeholder names, no app icons.
paint_menubar() {
  local names=("Cloud Sync" "Notes" "Clipboard" "Weather" "Calendar" "Display Agent")
  local i=1
  for name in "${names[@]}"; do
    $Y --set "widgets.menubar.row.$i" drawing=on \
      label="$name" label.color=0xffffffff \
      image.drawing=off icon.drawing=on icon="●" icon.color=0xff8e8e8e
    i=$((i + 1))
  done
  for i in $(seq 7 48); do
    $Y --set "widgets.menubar.row.$i" drawing=off
  done
  # The footer is whatever the last view set; the list view's own hint.
  $Y --set widgets.menubar.hint drawing=on icon="click opens · right-click hides"
}

record_seconds() {
  local secs=$1 dest=$2
  screencapture -x -v -V"$secs" "$dest" </dev/null
}

mov_to_gif() {
  local mov=$1 gif=$2 crop=$3 width=$4 fps=${5:-18}
  rm -f "$WORK"/frame-*.png
  $FFMPEG -y -i "$mov" -vf "$crop,fps=$fps,scale=${width}:-1:flags=lanczos" \
    "$WORK/frame-%04d.png" >/dev/null 2>&1
  $GIFSKI -o "$gif" --fps "$fps" --width "$width" "$WORK"/frame-*.png >/dev/null
  log "wrote $gif ($(du -h "$gif" | awk '{print $1}'))"
}

cleanup() {
  close_popups || true
  aerospace workspace "$RESTORE_WS" 2>/dev/null || true
}
trap cleanup EXIT

log "moving to empty workspace $EMPTY_WS (wallpaper only)"
osascript -e 'tell application "Finder" to activate' >/dev/null
aerospace workspace "$EMPTY_WS" 2>/dev/null || true
aerospace list-windows --workspace "$EMPTY_WS" --format '%{window-id}' 2>/dev/null | while read -r wid; do
  [ -n "$wid" ] && aerospace move-node-to-workspace Z --window-id "$wid" 2>/dev/null || true
done
close_popups
sleep 0.6

# ========== Widgets: calendar, monitor, battery, wifi, bluetooth, menu extras ==========
log "recording widget popups"

# Popup geometry, measured on this display. Everything is anchored to a pill
# the bar reports, so only these offsets are display-specific — the same rule
# the crop rectangles below follow.
read -r CPU_X CPU_Y <<<"$(centre_of widgets.cpu)"
read -r BATT_X BATT_Y <<<"$(centre_of widgets.battery)"
read -r CAL_X CAL_Y <<<"$(centre_of calendar)"
CAL_R="$(right_of calendar)"                 # the calendar popup is right-aligned to it
cal_col() { echo $(( CAL_R - 20 - (7 - $1) * 30 )); }   # centre of grid column 1..7
cal_row() { echo $(( 102 + 30 * $1 )); }                # centre of date row 1..6
CAL_PREV=$(( CAL_R - 200 )); CAL_TITLE=$(( CAL_R - 110 )); CAL_NEXT=$(( CAL_R - 20 ))
CAL_HDR_Y=62
CPU_CARD_Y=106; CPU_CARD2_Y=166                 # Memory, CPU
CPU_PLOT_Y=395; CPU_PLOT_L=$(( CPU_X - 140 )); CPU_PLOT_R=$(( CPU_X + 105 ))
BATT_PLOT_Y=430; BATT_PLOT_L=$(( CAL_R - 410 )); BATT_PLOT_R=$(( CAL_R - 55 ))
BATT_TAB_Y=218; BATT_TAB_10D=$(( CAL_R - 110 ))
PARK_X=760; PARK_Y=520                          # off the bar, so popups settle

(
  sleep 0.4
  # Calendar: open it, read three days off the grid, page a month forward and
  # back. Every one of those is a pointer interaction.
  tap "$CAL_X" "$CAL_Y"
  sleep 1.0
  glide "$CAL_X" "$CAL_Y" "$(cal_col 3)" "$(cal_row 2)" 10 0.025
  sleep 0.6
  glide "$(cal_col 3)" "$(cal_row 2)" "$(cal_col 6)" "$(cal_row 4)" 10 0.025
  sleep 0.7
  glide "$(cal_col 6)" "$(cal_row 4)" "$CAL_NEXT" "$CAL_HDR_Y" 10 0.025
  tap "$CAL_NEXT" "$CAL_HDR_Y"
  sleep 0.8
  tap "$CAL_NEXT" "$CAL_HDR_Y"
  sleep 0.8
  glide "$CAL_NEXT" "$CAL_HDR_Y" "$CAL_TITLE" "$CAL_HDR_Y" 8 0.025
  tap "$CAL_TITLE" "$CAL_HDR_Y"
  sleep 0.9
  $Y --set calendar.bracket popup.drawing=off

  # System monitor: the cards lift under the pointer, then the load history
  # is scrubbed — each bar reports its age and its load.
  sleep 0.3
  tap "$CPU_X" "$CPU_Y"
  sleep 0.9
  glide "$CPU_X" "$CPU_Y" "$CPU_X" "$CPU_CARD_Y" 10 0.03
  sleep 0.7
  glide "$CPU_X" "$CPU_CARD_Y" "$CPU_X" "$CPU_CARD2_Y" 8 0.035
  sleep 0.7
  glide "$CPU_X" "$CPU_CARD2_Y" "$CPU_PLOT_L" "$CPU_PLOT_Y" 12 0.03
  glide "$CPU_PLOT_L" "$CPU_PLOT_Y" "$CPU_PLOT_R" "$CPU_PLOT_Y" 20 0.05
  sleep 0.6
  $Y --set widgets.cpu.bracket popup.drawing=off

  # Battery: the charge history scrubs the same way, then the range switches.
  sleep 0.3
  tap "$BATT_X" "$BATT_Y"
  sleep 1.0
  glide "$BATT_X" "$BATT_Y" "$BATT_PLOT_L" "$BATT_PLOT_Y" 12 0.03
  glide "$BATT_PLOT_L" "$BATT_PLOT_Y" "$BATT_PLOT_R" "$BATT_PLOT_Y" 18 0.05
  sleep 0.5
  glide "$BATT_PLOT_R" "$BATT_PLOT_Y" "$BATT_TAB_10D" "$BATT_TAB_Y" 12 0.03
  tap "$BATT_TAB_10D" "$BATT_TAB_Y"
  sleep 1.4
  at "$PARK_X" "$PARK_Y"
  $Y --set widgets.battery.bracket popup.drawing=off
  sleep 0.25
  paint_wifi
  $Y --set widgets.wifi.bracket popup.drawing=on
  for _ in 1 2 3; do paint_wifi; sleep 0.28; done
  $Y --set widgets.wifi.bracket popup.drawing=off
  sleep 0.25
  paint_bluetooth
  $Y --set widgets.bluetooth.bracket popup.drawing=on
  for _ in 1 2 3 4; do paint_bluetooth; sleep 0.26; done
  $Y --set widgets.bluetooth.bracket popup.drawing=off
  # The liquid bar has no menu-extras widget.
  if $Y --query widgets.menubar.bracket >/dev/null 2>&1; then
    sleep 0.25
    $Y --set widgets.menubar.bracket popup.drawing=on
    for _ in 1 2 3 4 5; do paint_menubar; sleep 0.34; done
  fi
  close_popups
) &
SEQ=$!
record_seconds 24 "$WORK/popups.mov"
wait "$SEQ" 2>/dev/null || true
# Right side of the 3024-wide retina display, tall enough for the popups.
mov_to_gif "$WORK/popups.mov" "$OUT/ybar-popups.gif" "crop=1500:1500:1524:0" 760 15

# ========== Full bar: app-menu open and collapse, no windows ==========
log "recording bar + menu animation"
close_popups
# Workspace hops use EMPTY workspaces on purpose: the focused pill would
# otherwise carry a real app name and its icons into a public README. Empty
# ones still show the whole animation — the pill revealing, the ring moving
# to the selection, the rest sliding across.
PARK_X=${PARK_X:-760}; PARK_Y=${PARK_Y:-520}
WS_A="${YBAR_GIF_WS_A:-9}"
WS_B="${YBAR_GIF_WS_B:-A}"
(
  sleep 0.6
  $Y --trigger swap_menus_and_spaces
  sleep 2.2
  $Y --trigger swap_menus_and_spaces
  sleep 1.8
  aerospace workspace "$WS_A" 2>/dev/null || true
  sleep 1.1
  aerospace workspace "$WS_B" 2>/dev/null || true
  sleep 1.1
  aerospace workspace "$EMPTY_WS" 2>/dev/null || true
  sleep 1.0
  # A pass across the right cluster: every pill fades up under the pointer and
  # settles back behind it, which is the one animation a still can never show.
  read -r SWEEP_A _ <<<"$(centre_of widgets.menubar)"
  read -r SWEEP_B _ <<<"$(centre_of calendar)"
  glide "$SWEEP_A" 20 "$SWEEP_B" 20 34 0.045
  sleep 0.5
  at "$PARK_X" "$PARK_Y"
  sleep 0.7
) &
SEQ=$!
record_seconds 13 "$WORK/demo.mov"
wait "$SEQ" 2>/dev/null || true
# Bar strip only — nothing below the menu-bar band.
mov_to_gif "$WORK/demo.mov" "$OUT/ybar-demo.gif" "crop=3024:140:0:0" 1512 24

close_popups
log "done"
ls -la "$OUT"/ybar-demo.gif "$OUT"/ybar-popups.gif
