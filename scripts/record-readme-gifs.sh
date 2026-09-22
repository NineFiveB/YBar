#!/bin/bash
# Record README demo GIFs: wallpaper only, placeholder names (obfuscation, not redaction).
set -euo pipefail

Y="${YBAR:-/Users/wutts/Applications/YBar.app/Contents/MacOS/ybar}"
OUT="${1:-/Users/wutts/Documents/Development/YBar/docs/media}"
WORK="${TMPDIR:-/tmp}/ybar-gif-$$"
mkdir -p "$WORK" "$OUT"
FFMPEG=/opt/homebrew/bin/ffmpeg
GIFSKI=/opt/homebrew/bin/gifski
# Empty AeroSpace workspace so no app window is in frame.
EMPTY_WS="${YBAR_GIF_WORKSPACE:-8}"
RESTORE_WS="${YBAR_GIF_RESTORE:-2}"

log() { printf '[gif] %s\n' "$*"; }

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
    local i
    for i in 4 5 6; do
      $Y --set "widgets.bluetooth.dev.$i" drawing=off
    done
    $Y --set widgets.bluetooth.near.1 drawing=on icon="Pixel Buds"
    $Y --set widgets.bluetooth.near.2 drawing=on icon="MX Master"
    for i in 3 4 5 6; do
      $Y --set "widgets.bluetooth.near.$i" drawing=off
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
  for i in $(seq 7 26); do
    $Y --set "widgets.menubar.row.$i" drawing=off
  done
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
(
  sleep 0.3
  $Y --set calendar.bracket popup.drawing=on
  sleep 2.0
  $Y --set calendar.bracket popup.drawing=off
  sleep 0.3
  $Y --set widgets.cpu.bracket popup.drawing=on
  sleep 2.2
  $Y --set widgets.cpu.bracket popup.drawing=off
  sleep 0.3
  $Y --set widgets.battery.bracket popup.drawing=on
  sleep 2.2
  $Y --set widgets.battery.bracket popup.drawing=off
  sleep 0.25
  paint_wifi
  $Y --set widgets.wifi.bracket popup.drawing=on
  for _ in 1 2 3; do paint_wifi; sleep 0.35; done
  $Y --set widgets.wifi.bracket popup.drawing=off
  sleep 0.25
  paint_bluetooth
  $Y --set widgets.bluetooth.bracket popup.drawing=on
  for _ in 1 2 3 4; do paint_bluetooth; sleep 0.3; done
  $Y --set widgets.bluetooth.bracket popup.drawing=off
  # The liquid bar has no menu-extras widget.
  if $Y --query widgets.menubar.bracket >/dev/null 2>&1; then
    sleep 0.25
    $Y --set widgets.menubar.bracket popup.drawing=on
    for _ in 1 2 3 4 5; do paint_menubar; sleep 0.4; done
  fi
  close_popups
) &
SEQ=$!
record_seconds 18 "$WORK/popups.mov"
wait "$SEQ" 2>/dev/null || true
# Right side of the 3024-wide retina display, tall enough for the popups.
mov_to_gif "$WORK/popups.mov" "$OUT/ybar-popups.gif" "crop=1500:1500:1524:0" 780 16

# ========== Full bar: app-menu open and collapse, no windows ==========
log "recording bar + menu animation"
close_popups
(
  sleep 0.6
  $Y --trigger swap_menus_and_spaces
  sleep 2.4
  $Y --trigger swap_menus_and_spaces
  sleep 2.2
  $Y --trigger swap_menus_and_spaces
  sleep 1.6
  $Y --trigger swap_menus_and_spaces
  sleep 0.8
) &
SEQ=$!
record_seconds 8 "$WORK/demo.mov"
wait "$SEQ" 2>/dev/null || true
# Bar strip only — nothing below the menu-bar band.
mov_to_gif "$WORK/demo.mov" "$OUT/ybar-demo.gif" "crop=3024:140:0:0" 1512 24

close_popups
log "done"
ls -la "$OUT"/ybar-demo.gif "$OUT"/ybar-popups.gif
