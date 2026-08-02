#!/bin/bash

# Uses a compiled Swift EventKit helper to read calendar events
# without launching Calendar.app (the old AppleScript approach
# used "tell application Calendar" which opened the app every time).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWIFT_SRC="$SCRIPT_DIR/calendar_events.swift"
BINARY="$SCRIPT_DIR/calendar_events_bin"

# Compile if binary is missing or source is newer
if [ ! -f "$BINARY" ] || [ "$SWIFT_SRC" -nt "$BINARY" ]; then
  # Embed an Info.plist so EventKit's TCC prompt works for an unbundled binary.
  swiftc -O "$SWIFT_SRC" -o "$BINARY" -framework EventKit \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist \
    -Xlinker "$SCRIPT_DIR/calendar_events_info.plist" 2>/dev/null || exit 1
fi

exec "$BINARY"
