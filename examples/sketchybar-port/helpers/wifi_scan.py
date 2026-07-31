"""Parse `system_profiler SPAirPortDataType -json` (stdin) into TSV rows:

    current(0/1) \t ssid \t rssi \t secured(0/1)

Deduped by SSID keeping the strongest band; sorted current-first, then by
signal (unknown-signal networks last), then name. This is the only macOS
CLI source that still reports real SSIDs without location permission.
"""
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)

best = {}
current_name = None
for iface in data.get("SPAirPortDataType", [{}])[0].get("spairport_airport_interfaces", []):
    if iface.get("_name") != "en0":
        continue
    current = iface.get("spairport_current_network_information") or {}
    current_name = current.get("_name")
    networks = ([current] if current else []) + (
        iface.get("spairport_airport_other_local_wireless_networks") or [])
    for net in networks:
        name = net.get("_name")
        if not name:
            continue
        signal = net.get("spairport_signal_noise") or ""
        try:
            rssi = int(signal.split(" dBm")[0])
        except ValueError:
            rssi = -999
        mode = net.get("spairport_security_mode") or ""
        secured = 0 if (not mode or mode.endswith("_none")) else 1
        prev = best.get(name)
        if prev is None or rssi > prev[0]:
            best[name] = (rssi, secured)

ordered = sorted(
    best.items(),
    key=lambda kv: (kv[0] != current_name, kv[1][0] == -999, -kv[1][0], kv[0].lower()))
for name, (rssi, secured) in ordered:
    print(f"{1 if name == current_name else 0}\t{name}\t{rssi}\t{secured}")
