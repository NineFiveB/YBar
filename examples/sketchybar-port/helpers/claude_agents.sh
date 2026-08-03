#!/bin/sh
# Claude Code activity probe: counts agent sessions by the write recency of
# their JSONL transcripts under ~/.claude/projects (the same signal
# so-agentbar watches, polled instead of FSEvents-driven).
#   active  = session log written within the last 2 minutes
#   working = session log written within the last 10 seconds (streaming now)
# maxdepth 2 keeps this to top-level sessions — subagent transcripts nest
# deeper and would multiply-count one session's fan-out.
# Output: "<active> <working>"
dir="$HOME/.claude/projects"
now=$(date +%s)
active=0
working=0
for f in $(find "$dir" -maxdepth 2 -name '*.jsonl' -mmin -3 2>/dev/null); do
  m=$(stat -f %m "$f" 2>/dev/null) || continue
  age=$((now - m))
  if [ "$age" -le 120 ]; then
    active=$((active + 1))
    [ "$age" -le 10 ] && working=$((working + 1))
  fi
done
echo "$active $working"
