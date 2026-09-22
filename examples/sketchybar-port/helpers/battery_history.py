"""Bucket battery charge history from `pmset -g log` (stdin).

Usage:
  pmset -g log | python3 battery_history.py [buckets] [hours]
      Prints two lines covering the last `hours` (default 24). The first is
      N space-separated integers 0-100; gaps are forward-filled from the
      first sample, matching the previous one-line output. The second is
      N flags, 1 when that bucket was actively charging (on AC below 100%,
      or the charge rose) and 0 otherwise.

  pmset -g log | python3 battery_history.py daily [days]
      One integer per calendar day, oldest first: percent-points of charge
      used that day (drops only), capped at 150. This is the System Settings
      "Energy Usage" scale for the last N days (default 10).

  pmset -g log | python3 battery_history.py last
      Prints `PCT|WHEN` for the most recent AC charge peak (best-effort
      "Last charged to …" row). WHEN is a short local string.
"""
import re
import sys
import time
from datetime import datetime, timedelta


def parse_ts(stamp: str):
    try:
        return time.mktime(time.strptime(stamp, "%Y-%m-%d %H:%M:%S"))
    except ValueError:
        return None


def bucket_history(hours: float, n: int) -> None:
    """Charge level per bucket, then a 0/1 charging flag per bucket.

    AC state carries forward, including from before the window, so a quiet
    stretch while plugged in stays marked. A bucket is charging when that
    carried state is AC and the level is under 100%, or the percent rose
    in the bucket. Sitting on AC at 100% is not actively charging.
    """
    now = time.time()
    window = hours * 3600
    start = now - window
    n = max(1, n)
    percents = [None] * n
    rose = [False] * n
    # Last AC state observed inside the bucket; None if the bucket was quiet.
    ac_at = [None] * n
    on_ac = False
    prev_pct = None
    ac_before = False

    def index_for(ts: float):
        if ts < start or ts > now:
            return None
        idx = int((ts - start) / window * n)
        if idx >= n:
            idx = n - 1
        return idx if idx >= 0 else None

    for line in sys.stdin:
        stamp_m = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", line)
        if not stamp_m:
            continue
        ts = parse_ts(stamp_m.group(1))
        if ts is None:
            continue
        body = line.lower()
        if "using ac" in body or "ac attached" in body:
            on_ac = True
        if "using battery" in body:
            on_ac = False
        charged_to = re.search(r"charged to\s*(\d+)%", body)
        if charged_to:
            on_ac = True
            prev_pct = int(charged_to.group(1))
        if "finished charging" in body or "fullycharged" in body:
            on_ac = True
            prev_pct = 100
        charge = re.search(r"charge:\s*(\d+)\s*%?", body)
        pct = int(charge.group(1)) if charge else None
        if pct is not None and prev_pct is not None and pct > prev_pct:
            rose_idx = index_for(ts)
            if rose_idx is not None:
                rose[rose_idx] = True
        if pct is not None:
            prev_pct = pct
        idx = index_for(ts)
        if idx is None:
            if ts < start:
                ac_before = on_ac
            continue
        ac_at[idx] = on_ac
        if pct is not None:
            percents[idx] = pct

    # Same fill as before: leading gaps take the first later sample.
    prev = next((b for b in percents if b is not None), None)
    out = []
    known = []
    for b in percents:
        if b is None:
            known.append(prev is not None)
            out.append(prev if prev is not None else 0)
        else:
            prev = b
            known.append(True)
            out.append(b)

    ac = ac_before
    flags = []
    for i in range(n):
        if ac_at[i] is not None:
            ac = ac_at[i]
        charging = known[i] and ((ac and out[i] < 100) or rose[i])
        flags.append("1" if charging else "0")
    print(" ".join(str(v) for v in out))
    print(" ".join(flags))


def format_when(ts: float) -> str:
    dt = datetime.fromtimestamp(ts)
    now = datetime.now()
    if sys.platform == "win32":
        clock = dt.strftime("%I:%M %p").lstrip("0")
        dated = dt.strftime("%b %d, ") + clock
    else:
        clock = dt.strftime("%-I:%M %p")
        dated = dt.strftime("%b %-d, ") + clock
    if dt.date() == now.date():
        return f"Today, {clock}"
    if (now.date() - dt.date()).days == 1:
        return f"Yesterday, {clock}"
    return dated


charge_pat = re.compile(r"Charge:\s*(\d+)\s*%?")


def daily_usage(days: int) -> None:
    """Percent of battery capacity consumed each calendar day, oldest first.

    A drop from 80% to 30% adds 50. Charging does not. Days the machine
    stayed on AC stay near 0 because the charge level does not fall; that is
    all `pmset -g log` records. Capped at 150, the System Settings axis.
    """
    days = max(1, days)
    now = datetime.now()
    start = (now - timedelta(days=days - 1)).date()
    usage = [0] * days
    prev = None
    for line in sys.stdin:
        stamp_m = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", line)
        if not stamp_m:
            continue
        ts = parse_ts(stamp_m.group(1))
        if ts is None:
            continue
        cm = charge_pat.search(line)
        if not cm:
            continue
        pct = int(cm.group(1))
        if prev is not None and pct < prev:
            day = datetime.fromtimestamp(ts).date()
            index = (day - start).days
            if 0 <= index < days:
                usage[index] += prev - pct
        prev = pct
    print(" ".join(str(min(150, value)) for value in usage))


def last_charged_scan() -> None:
    """Single-pass scan: track AC state and remember the latest peak."""
    peak_pct = None
    peak_ts = None
    on_ac = False
    last_pct = None
    last_ts = None
    for line in sys.stdin:
        stamp_m = re.match(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})", line)
        if not stamp_m:
            continue
        ts = parse_ts(stamp_m.group(1))
        if ts is None:
            continue
        body = line.lower()
        if "using ac" in body or "ac attached" in body:
            on_ac = True
        if "using battery" in body:
            on_ac = False
        cm = re.search(r"charged to\s*(\d+)%", body)
        if cm:
            on_ac = True
            peak_pct, peak_ts = int(cm.group(1)), ts
            continue
        if "finished charging" in body or "fullycharged" in body:
            on_ac = True
            peak_pct, peak_ts = 100, ts
            continue
        cm = re.search(r"charge:\s*(\d+)%", body)
        if not cm:
            continue
        pct = int(cm.group(1))
        last_pct, last_ts = pct, ts
        if on_ac:
            if peak_pct is None or pct >= peak_pct:
                peak_pct, peak_ts = pct, ts
            elif peak_ts is not None and ts - peak_ts > 6 * 3600:
                peak_pct, peak_ts = pct, ts

    if peak_pct is None:
        if last_pct is None:
            print("—|—")
            return
        peak_pct, peak_ts = last_pct, last_ts
    print(f"{peak_pct}|{format_when(peak_ts)}")


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "last":
        last_charged_scan()
    elif len(sys.argv) > 1 and sys.argv[1] == "daily":
        days = int(sys.argv[2]) if len(sys.argv) > 2 else 10
        daily_usage(days)
    else:
        n = int(sys.argv[1]) if len(sys.argv) > 1 else 216
        hours = float(sys.argv[2]) if len(sys.argv) > 2 else 24.0
        bucket_history(hours, n)
