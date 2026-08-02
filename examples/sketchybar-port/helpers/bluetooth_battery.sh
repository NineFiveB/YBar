#!/usr/bin/env zsh
DEBUG_LOG=/dev/null
# Lists paired Bluetooth devices with battery levels and device types.
# Output: one line per device: name|address|connected|battery|type
#   battery = -1 when not available
#   type = one of: headset, keyboard, trackpad, phone, speaker, generic
# Requires: blueutil (brew install blueutil)

# Use absolute paths for system tools (sketchybar runs with minimal PATH)
GREP=/usr/bin/grep
SED=/usr/bin/sed
TR=/usr/bin/tr
PYTHON=""
for py in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
  [[ -x "$py" ]] && PYTHON="$py" && break
done
[[ -z "$PYTHON" ]] && PYTHON=$(command -v python3 2>/dev/null)
[[ -z "$PYTHON" ]] && exit 1

# ── Locate blueutil ──────────────────────────────────────────────────────────
BLUEUTIL=""
for path in /opt/homebrew/bin/blueutil /usr/local/bin/blueutil; do
  [[ -x "$path" ]] && BLUEUTIL="$path" && break
done
[[ -z "$BLUEUTIL" ]] && exit 1

# ── Gather data in parallel ──────────────────────────────────────────────────
# Use narrow ioreg queries instead of full `ioreg -l` (90x faster)
typeset -A BATTERIES_BY_ADDR

# Temporary files for parallel execution
tmpdir=$(/usr/bin/mktemp -d)
trap "/bin/rm -rf '$tmpdir'" EXIT

# 1) IOBluetoothDevice for BT device addresses + batteries
/usr/sbin/ioreg -r -c IOBluetoothDevice -l 2>/dev/null \
  | $GREP -E '"BD_ADDR"|"DeviceAddress"|"BatteryPercent"' > "$tmpdir/ioreg_bt" &

# 2) AppleDeviceManagementHIDEventService for HID batteries (trackpad, keyboard)
/usr/sbin/ioreg -r -c AppleDeviceManagementHIDEventService -l 2>/dev/null \
  | $GREP -E '"DeviceAddress"|"BatteryPercent"' > "$tmpdir/ioreg_hid" &

# 3) system_profiler for device types
/usr/sbin/system_profiler SPBluetoothDataType 2>/dev/null > "$tmpdir/sp_data" &

# 4) blueutil paired devices
"$BLUEUTIL" --paired --format json 2>/dev/null > "$tmpdir/paired" &

# 5) pmset for accessory batteries (headphones, etc. that don't expose BatteryPercent via ioreg)
/usr/bin/pmset -g everything 2>/dev/null > "$tmpdir/pmset" &

# Wait for all parallel jobs
wait

# ── Parse ioreg battery data ─────────────────────────────────────────────────
prev_addr=""
for f in "$tmpdir/ioreg_bt" "$tmpdir/ioreg_hid"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    if [[ "$line" == *'"BD_ADDR"'* ]]; then
      prev_addr=$($SED -n 's/.*<\([0-9a-f]*\)>.*/\1/p' <<< "$line")
    elif [[ "$line" == *'"DeviceAddress"'* ]]; then
      # Handle both <hex> and "xx-xx-…" formats
      raw=$($SED -n 's/.*<\([0-9a-f]*\)>.*/\1/p' <<< "$line")
      if [[ -z "$raw" ]]; then
        raw=$($SED -n 's/.*"\([0-9a-fA-F-]*\)".*/\1/p' <<< "$line")
        raw=$(echo "$raw" | $TR -d '-' | $TR '[:upper:]' '[:lower:]')
      fi
      [[ -n "$raw" ]] && prev_addr="$raw"
    fi
    if [[ "$line" == *'"BatteryPercent"'* && -n "$prev_addr" ]]; then
      batt=$($SED -n 's/.*= \([0-9]*\).*/\1/p' <<< "$line")
      [[ -n "$batt" ]] && BATTERIES_BY_ADDR[$prev_addr]="$batt"
      prev_addr=""
    fi
  done < "$f"
done

# ── Parse pmset accessory batteries (headphones, speakers, etc.) ─────────────
# Maps device name -> battery percent for Bluetooth accessories
typeset -A PMSET_BATTERIES
if [[ -f "$tmpdir/pmset" ]]; then
  # Use Python to extract Bluetooth accessory batteries from pmset plist output
  $PYTHON -c "
import re

data = open('$tmpdir/pmset', encoding='utf-8', errors='replace').read()

# Split into plist sections
sections = data.split('<?xml version=')
for section in sections:
    if 'Bluetooth' not in section:
        continue
    name_match = re.search(r'<key>Name</key>\s*<string>(.*?)</string>', section)
    cap_match = re.search(r'<key>Current Capacity</key>\s*<integer>(\d+)</integer>', section)
    transport_match = re.search(r'<key>Transport Type</key>\s*<string>(.*?)</string>', section)

    if name_match and cap_match and transport_match:
        if transport_match.group(1) == 'Bluetooth':
            print(f'{name_match.group(1)}|{cap_match.group(1)}')
" 2>/dev/null > "$tmpdir/pmset_parsed"

  while IFS='|' read -r pname pbatt; do
    [[ -n "$pname" && -n "$pbatt" ]] && PMSET_BATTERIES[$pname]="$pbatt"
  done < "$tmpdir/pmset_parsed"
  echo "PMSET_BATTERIES keys: ${(k)PMSET_BATTERIES[@]}" >> "$DEBUG_LOG"
fi

# ── Gather device types from system_profiler ─────────────────────────────────
typeset -A DEVICE_TYPES
current_name=""
while IFS= read -r line; do
  if [[ "$line" =~ ^[[:space:]]{8,12}[^[:space:]].*:$ ]]; then
    current_name="${line##*( )}"
    current_name="${current_name%:}"
  fi
  if [[ -n "$current_name" && "$line" == *"Minor Type:"* ]]; then
    minor="${line##*Minor Type: }"
    minor="${minor## }"
    case "$minor" in
      *Headset*|*Headphone*|*Earbuds*) DEVICE_TYPES[$current_name]="headset" ;;
      *Keyboard*)                       DEVICE_TYPES[$current_name]="keyboard" ;;
      *Trackpad*|*Mouse*)               DEVICE_TYPES[$current_name]="trackpad" ;;
      *Phone*)                          DEVICE_TYPES[$current_name]="phone" ;;
      *Speaker*)                        DEVICE_TYPES[$current_name]="speaker" ;;
      *)                                DEVICE_TYPES[$current_name]="generic" ;;
    esac
  fi
done < "$tmpdir/sp_data"

# ── List paired devices and merge all data ───────────────────────────────────
# Try blueutil first, fall back to system_profiler if it fails
device_lines=""
if [[ -s "$tmpdir/paired" ]]; then
  device_lines=$($PYTHON -c "
import sys, json
try:
    devices = json.load(sys.stdin)
    for d in devices:
        name = d.get('name', d.get('address', 'Unknown'))
        addr = d.get('address', '')
        conn = '1' if d.get('connected', False) else '0'
        print(f'{name}|{addr}|{conn}')
except:
    pass
" < "$tmpdir/paired" 2>/dev/null)
fi

# Fallback: parse system_profiler for device list
if [[ -z "$device_lines" && -s "$tmpdir/sp_data" ]]; then
  device_lines=$($PYTHON -c "
import json, subprocess, sys

data = json.load(sys.stdin)
bt = data.get('SPBluetoothDataType', [{}])[0]

for section_key in ['device_connected', 'device_not_connected']:
    connected = '1' if section_key == 'device_connected' else '0'
    devices = bt.get(section_key, [])
    for dev_dict in devices:
        for name, info in dev_dict.items():
            addr = info.get('device_address', '')
            print(f'{name}|{addr}|{connected}')
" < <(/usr/sbin/system_profiler SPBluetoothDataType -json 2>/dev/null) 2>/dev/null)
fi

while IFS='|' read -r name address connected; do
  [[ -z "$name" ]] && continue
  # Normalize address for ioreg lookup: 04-41-a5-8c-19-60 or 04:41:A5:8C:19:60 -> 0441a58c1960
  addr_hex=$(echo "$address" | $TR -d '-' | $TR -d ':' | $TR '[:upper:]' '[:lower:]')
  battery="${BATTERIES_BY_ADDR[$addr_hex]:--1}"
  # Fallback: check pmset accessory batteries by device name
  if [[ "$battery" == "-1" && -n "${PMSET_BATTERIES[$name]}" ]]; then
    battery="${PMSET_BATTERIES[$name]}"
  fi
  dtype="${DEVICE_TYPES[$name]:-generic}"

  # Heuristic fallback for type detection by name
  if [[ "$dtype" == "generic" ]]; then
    lname="${name:l}"
    case "$lname" in
      *headphone*|*xm5*|*xm4*|*buds*|*airpod*|*beats*|*earbuds*) dtype="headset" ;;
      *keyboard*|*yunzii*|*keychron*|*nuphy*)                      dtype="keyboard" ;;
      *trackpad*|*mouse*|*mx\ *)                                   dtype="trackpad" ;;
      *iphone*|*phone*)                                            dtype="phone" ;;
      *speaker*|*homepod*)                                         dtype="speaker" ;;
    esac
  fi

  echo "${name}|${address}|${connected}|${battery}|${dtype}"
done <<< "$device_lines"
