#!/bin/sh
# Rich system snapshot for the cpu widget popup: KEY=VALUE lines.
# top runs two samples because the first reports since-boot averages.

top -l 2 -s 1 -n 0 2>/dev/null | awk '
  /^CPU usage/ { u = $3; s = $5; i = $7 }
  /^PhysMem/   { m = $2 }
  END {
    gsub("%", "", u); gsub("%", "", s); gsub("%", "", i)
    printf "CPU_USER=%s\nCPU_SYS=%s\nCPU_IDLE=%s\nMEM_USED=%s\n", u, s, i, m
  }'

sysctl -n vm.loadavg 2>/dev/null | awk '{ printf "LOAD1=%s\nLOAD5=%s\nLOAD15=%s\n", $2, $3, $4 }'

ps -Aceo pcpu,comm -r 2>/dev/null | sed -n 2p | awk '
  { c = $1; $1 = ""; sub(/^ +/, ""); printf "TOP_CPU=%s\nTOP_NAME=%s\n", c, $0 }'

echo "NCPU=$(sysctl -n hw.ncpu 2>/dev/null)"
echo "MEM_TOTAL_BYTES=$(sysctl -n hw.memsize 2>/dev/null)"
sysctl -n vm.swapusage 2>/dev/null | awk '{ printf "SWAP_USED=%s\n", $6 }'

case "$(sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null)" in
  1) echo "MEM_PRESSURE=Normal" ;;
  2) echo "MEM_PRESSURE=Warning" ;;
  4) echo "MEM_PRESSURE=Critical" ;;
  *) echo "MEM_PRESSURE=—" ;;
esac

df -H /System/Volumes/Data 2>/dev/null | awk '
  NR == 2 { printf "DISK_SIZE=%s\nDISK_USED=%s\nDISK_AVAIL=%s\nDISK_PCT=%s\n", $2, $3, $4, $5 }'

ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null \
  | grep -o '"Device Utilization %"=[0-9]*' | head -1 \
  | awk -F= '{ print "GPU=" $2 }'

sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]' '{ print "BOOT_SEC=" $4 }'
