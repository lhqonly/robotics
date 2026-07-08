#!/usr/bin/env bash
# Periodically run no-flash communication smoke tests and handoff reports.
#
# This is intended for unattended hardware nights when SWD may be blocked but
# the serial/micro-ROS link can still be monitored. It never builds or flashes.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_PREFIX="${1:-overnight_$(date +%Y%m%d_%H%M)}"
LOGDIR="${LOGDIR:-$ROOT/log/overnight-com-watch}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1800}"
END_AT="${END_AT:-tomorrow 09:00}"
RUN_SECONDS="${RUN_SECONDS:-18}"
WARMUP_SECONDS="${WARMUP_SECONDS:-5}"
HZ_SECONDS="${HZ_SECONDS:-10}"
WIRE_EVERY_N="${WIRE_EVERY_N:-0}"
WIRE_AGENT_VERBOSITY="${WIRE_AGENT_VERBOSITY:-6}"
PC_LAUNCH_PREFIX="${PC_LAUNCH_PREFIX:-}"

mkdir -p "$LOGDIR"
LOG="$LOGDIR/$TAG_PREFIX.log"
SUMMARY_MD="$LOGDIR/$TAG_PREFIX.summary.md"
SUMMARY_CSV="$LOGDIR/$TAG_PREFIX.summary.csv"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "$LOG"
}

write_summary() {
  if "$ROOT/tools/summarize-overnight-com-watch.sh" "$LOG" >"$SUMMARY_MD" 2>>"$LOG" &&
      FORMAT=csv "$ROOT/tools/summarize-overnight-com-watch.sh" "$LOG" >"$SUMMARY_CSV" 2>>"$LOG"; then
    log "summary=ok markdown=${SUMMARY_MD#$ROOT/} csv=${SUMMARY_CSV#$ROOT/}"
  else
    log "summary=fail"
  fi
}

end_epoch="$(date -d "$END_AT" +%s 2>/dev/null || true)"
if [ -z "$end_epoch" ]; then
  echo "ERROR: cannot parse END_AT='$END_AT'" >&2
  exit 1
fi

log "start tag_prefix=$TAG_PREFIX end_at=$END_AT interval_s=$INTERVAL_SECONDS wire_every_n=$WIRE_EVERY_N pc_launch_prefix=${PC_LAUNCH_PREFIX:-none}"
iteration=0
while [ "$(date +%s)" -lt "$end_epoch" ]; do
  iteration=$((iteration + 1))
  tag="${TAG_PREFIX}_$(printf '%03d' "$iteration")"
  agent_verbosity=1
  if [ "$WIRE_EVERY_N" -gt 0 ] 2>/dev/null && [ $((iteration % WIRE_EVERY_N)) -eq 0 ]; then
    agent_verbosity="$WIRE_AGENT_VERBOSITY"
  fi
  log "iteration=$iteration smoke tag=$tag agent_verbosity=$agent_verbosity"

  if BUILD_FIRMWARE=0 FLASH_FIRMWARE=0 RESET_TARGET=0 \
      RUN_SECONDS="$RUN_SECONDS" \
      WARMUP_SECONDS="$WARMUP_SECONDS" \
      HZ_SECONDS="$HZ_SECONDS" \
      MICROROS_AGENT_VERBOSITY="$agent_verbosity" \
      PC_LAUNCH_PREFIX="$PC_LAUNCH_PREFIX" \
      "$ROOT/tools/run-com-perf.sh" "$tag" >>"$LOG" 2>&1; then
    log "iteration=$iteration smoke=ok"
  else
    log "iteration=$iteration smoke=fail status=$?"
  fi

  if "$ROOT/tools/com-status-report.sh" "$tag" >>"$LOG" 2>&1; then
    log "iteration=$iteration report=ok"
  else
    log "iteration=$iteration report=fail status=$?"
  fi
  write_summary

  now="$(date +%s)"
  next=$((now + INTERVAL_SECONDS))
  if [ "$next" -gt "$end_epoch" ]; then
    break
  fi
  log "sleep_s=$INTERVAL_SECONDS"
  sleep "$INTERVAL_SECONDS"
done

final_tag="${TAG_PREFIX}_final"
log "final_report tag=$final_tag"
"$ROOT/tools/com-status-report.sh" "$final_tag" >>"$LOG" 2>&1 || true
write_summary
log "done log=$LOG"
