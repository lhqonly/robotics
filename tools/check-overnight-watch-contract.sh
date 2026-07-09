#!/usr/bin/env bash
# Acceptance gate for unattended no-flash overnight communication watch runs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_LOGDIR="${WATCH_LOGDIR:-$ROOT/log/overnight-com-watch}"
SUMMARY_CMD="${SUMMARY_CMD:-$ROOT/tools/summarize-overnight-com-watch.sh}"
WATCH_STATUS_CMD="${WATCH_STATUS_CMD:-$ROOT/tools/overnight-watch-status.sh}"
INPUT="${1:-}"
MIN_SAMPLES="${MIN_SAMPLES:-2}"
MAX_FAILS="${MAX_FAILS:-0}"
MAX_WARNS="${MAX_WARNS:-0}"
MAX_LOST="${MAX_LOST:-0}"
MAX_DUPLICATE="${MAX_DUPLICATE:-0}"
MAX_CATCHUP_EVENTS="${MAX_CATCHUP_EVENTS:-0}"
MAX_CATCHUP_EXTRA="${MAX_CATCHUP_EXTRA:-0}"
REQUIRE_ACTIVE_FRESH="${REQUIRE_ACTIVE_FRESH:-0}"

latest_watch_log() {
  find "$WATCH_LOGDIR" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null |
    sort -nr |
    awk 'NR == 1 {sub(/^[^ ]+ /, ""); print; exit}'
}

if [ -z "$INPUT" ]; then
  WATCH_LOG="$(latest_watch_log)"
elif [ -f "$INPUT" ]; then
  WATCH_LOG="$INPUT"
else
  WATCH_LOG="$WATCH_LOGDIR/$INPUT.log"
fi

if [ -z "${WATCH_LOG:-}" ] || [ ! -f "$WATCH_LOG" ]; then
  echo "FAIL overnight_watch_contract reason=missing_watch_log input=${INPUT:-latest}"
  exit 1
fi
if [ ! -x "$SUMMARY_CMD" ]; then
  echo "FAIL overnight_watch_contract reason=missing_summary_cmd"
  exit 1
fi

csv="$(FORMAT=csv "$SUMMARY_CMD" "$WATCH_LOG")"
metrics="$(
  printf '%s\n' "$csv" |
    awk -F, -v min_samples="$MIN_SAMPLES" \
      -v max_fails="$MAX_FAILS" \
      -v max_warns="$MAX_WARNS" \
      -v max_lost="$MAX_LOST" \
      -v max_duplicate="$MAX_DUPLICATE" \
      -v max_catchup_events="$MAX_CATCHUP_EVENTS" \
      -v max_catchup_extra="$MAX_CATCHUP_EXTRA" '
      NR == 1 {
        for (i = 1; i <= NF; i++) col[$i] = i
        next
      }
      function num(value) {
        return (value == "" || value == "NA" || value == "-") ? 0 : value + 0
      }
      {
        samples += 1
        verdict = $col["verdict"]
        if (verdict == "FAIL") fails += 1
        if (verdict == "WARN") warns += 1
        lost += num($col["lost"])
        duplicate += num($col["duplicate"])
        catchup_events += num($col["pc_cmd_catchup_events"])
        catchup_extra += num($col["pc_cmd_catchup_extra"])
      }
      END {
        reason = ""
        if (samples < min_samples) reason = reason "samples_low;"
        if (fails > max_fails) reason = reason "fails_high;"
        if (warns > max_warns) reason = reason "warns_high;"
        if (lost > max_lost) reason = reason "lost_high;"
        if (duplicate > max_duplicate) reason = reason "duplicate_high;"
        if (catchup_events > max_catchup_events) reason = reason "catchup_events_high;"
        if (catchup_extra > max_catchup_extra) reason = reason "catchup_extra_high;"
        if (reason == "") reason = "-"
        printf("samples=%d fails=%d warns=%d lost=%g duplicate=%g catchup_events=%g catchup_extra=%g reason=%s\n",
          samples, fails + 0, warns + 0, lost + 0, duplicate + 0,
          catchup_events + 0, catchup_extra + 0, reason)
      }
    '
)"

reason="$(printf '%s\n' "$metrics" | sed -nE 's/.* reason=([^ ]+).*/\1/p')"
metrics_body="$(printf '%s\n' "$metrics" | sed -E 's/ reason=[^ ]+//')"
watch_tag="$(basename "$WATCH_LOG" .log)"
active_status="skipped"
append_reason() {
  if [ "$reason" = "-" ] || [ -z "$reason" ]; then
    reason="$1"
  else
    reason="${reason};$1"
  fi
}

if [ "$REQUIRE_ACTIVE_FRESH" = "1" ]; then
  if [ ! -x "$WATCH_STATUS_CMD" ]; then
    append_reason "missing_watch_status_cmd"
    active_status="missing"
  else
    active_line="$("$WATCH_STATUS_CMD" 2>/dev/null | awk -v tag="$watch_tag" '$0 ~ "tag=" tag " " {print; exit}')"
    if [ -z "$active_line" ]; then
      append_reason "active_watcher_missing"
      active_status="missing"
    elif printf '%s\n' "$active_line" | grep -q 'freshness=fresh'; then
      active_status="fresh"
    else
      append_reason "active_watcher_not_fresh"
      active_status="not_fresh"
    fi
  fi
fi
reason="$(printf '%s' "$reason" | sed 's/^-;//; s/^;//; s/;$//')"

if [ "$reason" = "-" ] || [ -z "$reason" ]; then
  echo "PASS overnight_watch_contract log=${WATCH_LOG#$ROOT/} $metrics_body active=$active_status"
  exit 0
fi

echo "FAIL overnight_watch_contract log=${WATCH_LOG#$ROOT/} $metrics_body active=$active_status reason=$reason"
exit 1
