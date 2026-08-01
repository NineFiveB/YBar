"""Bucket battery charge history from `pmset -g log` (stdin) into N slots
covering the last 24 hours. Prints N space-separated integers 0-100;
gaps are forward-filled (the battery level between log entries is
whatever it was at the previous entry).

Usage: pmset -g log | python3 battery_history.py [buckets]
"""
import re
import sys
import time

n = int(sys.argv[1]) if len(sys.argv) > 1 else 216
now = time.time()
window = 24 * 3600

pat = re.compile(
    r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) [+-]\d{4}.*?Charge:\s*(\d+)%")

buckets = [None] * n
for line in sys.stdin:
    m = pat.match(line)
    if not m:
        continue
    try:
        ts = time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except ValueError:
        continue
    age = now - ts
    if 0 <= age <= window:
        idx = int((ts - (now - window)) / window * n)
        if 0 <= idx < n:
            buckets[idx] = int(m.group(2))  # last write per bucket wins

prev = next((b for b in buckets if b is not None), None)
out = []
for b in buckets:
    if b is None:
        b = prev
    else:
        prev = b
    out.append(b if b is not None else 0)
print(" ".join(str(v) for v in out))
