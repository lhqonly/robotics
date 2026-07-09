#!/usr/bin/env bash
# Summarize micro-ROS Agent serial debug logs by direction and frame length.
set -euo pipefail

LOG="${1:-}"
SKIP_SECONDS="${SKIP_SECONDS:-${2:-0}}"
BAUD="${BAUD:-921600}"

if [ -z "$LOG" ]; then
  echo "usage: BAUD=921600 SKIP_SECONDS=3 tools/agent-wire-stats.sh <agent-v6.log>" >&2
  exit 2
fi
if [ ! -f "$LOG" ]; then
  echo "ERROR: log not found: $LOG" >&2
  exit 1
fi

awk -v baud="$BAUD" -v skip_s="$SKIP_SECONDS" '
function strip_ansi(s) {
  gsub(/\033\[[0-9;]*m/, "", s)
  return s
}
function parse_ts(s,   t) {
  if (match(s, /\[[0-9]+\.[0-9]+\]/)) {
    t = substr(s, RSTART + 1, RLENGTH - 2)
    return t + 0
  }
  return -1
}
function parse_len(s,   t) {
  if (match(s, /len:[[:space:]]*[0-9]+/)) {
    t = substr(s, RSTART, RLENGTH)
    gsub(/[^0-9]/, "", t)
    return t + 0
  }
  return -1
}
function remember_len(dir, len, key) {
  key = dir SUBSEP len
  if (!(key in hist)) {
    hist_order[++hist_order_count] = key
  }
  hist[key]++
}
function emit_dir(dir, label, duration_s,   avg, fps, bps, kbps10, util) {
  if (frames[dir] == 0) {
    printf "%-14s %8d %10d %8s %10s %10s %12s %8s\n", label, 0, 0, "-", "-", "-", "-", "-"
    return
  }
  avg = bytes[dir] / frames[dir]
  fps = frames[dir] / duration_s
  bps = bytes[dir] / duration_s
  kbps10 = bps * 10.0 / 1000.0
  util = baud > 0 ? (bps * 10.0 * 100.0 / baud) : 0.0
  printf "%-14s %8d %10d %8.1f %10.2f %10.1f %12.2f %7.2f%%\n", \
    label, frames[dir], bytes[dir], avg, fps, bps, kbps10, util
}
BEGIN {
  if (baud <= 0) {
    baud = 921600
  }
}
{
  line = strip_ansi($0)
  if (line !~ /SerialAgentLinux\.cpp/) {
    next
  }
  if (line !~ /(send_message|recv_message)/) {
    next
  }
  ts = parse_ts(line)
  len = parse_len(line)
  if (ts < 0 || len < 0) {
    next
  }
  if (!seen_any) {
    base_ts = ts
    seen_any = 1
  }
  if (skip_s > 0 && ts < base_ts + skip_s) {
    next
  }
  dir = line ~ /send_message/ ? "tx" : "rx"
  if (!(dir in frames)) {
    first_ts[dir] = ts
  }
  frames[dir]++
  bytes[dir] += len
  last_ts[dir] = ts
  remember_len(dir, len)
  if (!included_any || ts < first_included_ts) {
    first_included_ts = ts
  }
  if (!included_any || ts > last_included_ts) {
    last_included_ts = ts
  }
  included_any = 1
}
END {
  if (!included_any) {
    print "ERROR: no SerialAgentLinux send_message/recv_message lines found after skip window" > "/dev/stderr"
    exit 1
  }
  duration_s = last_included_ts - first_included_ts
  if (duration_s <= 0) {
    duration_s = 1e-9
  }
  total_frames = frames["tx"] + frames["rx"]
  total_bytes = bytes["tx"] + bytes["rx"]
  total_kbps10 = total_bytes / duration_s * 10.0 / 1000.0
  total_util = total_bytes / duration_s * 10.0 * 100.0 / baud
  tx_kbps10 = bytes["tx"] / duration_s * 10.0 / 1000.0
  rx_kbps10 = bytes["rx"] / duration_s * 10.0 / 1000.0
  tx_fps = frames["tx"] / duration_s
  rx_fps = frames["rx"] / duration_s

  printf "log=%s\n", FILENAME
  printf "skip_seconds=%.3f duration_s=%.3f baud=%d async_bits_per_byte=10\n", \
    skip_s, duration_s, baud
  printf "total_frames=%d total_bytes=%d total_serial_kbit_s=%.2f baud_util=%.2f%%\n\n", \
    total_frames, total_bytes, total_kbps10, total_util
  printf "METRICS duration_s=%.3f total_frames=%d total_bytes=%d total_serial_kbit_s=%.2f baud_util_pct=%.2f tx_serial_kbit_s=%.2f rx_serial_kbit_s=%.2f tx_frames_s=%.2f rx_frames_s=%.2f\n\n", \
    duration_s, total_frames, total_bytes, total_kbps10, total_util, \
    tx_kbps10, rx_kbps10, tx_fps, rx_fps

  printf "%-14s %8s %10s %8s %10s %10s %12s %8s\n", \
    "direction", "frames", "bytes", "avg_len", "frames/s", "bytes/s", "serial kbit/s", "baud util"
  emit_dir("tx", "agent->mcu", duration_s)
  emit_dir("rx", "mcu->agent", duration_s)

  print ""
  print "frame_length_histogram:"
  for (i = 1; i <= hist_order_count; i++) {
    split(hist_order[i], parts, SUBSEP)
    label = parts[1] == "tx" ? "agent->mcu" : "mcu->agent"
    printf "%-14s len=%4d count=%d\n", label, parts[2], hist[hist_order[i]]
  }
}
' "$LOG"
