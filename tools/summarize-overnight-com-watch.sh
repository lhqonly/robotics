#!/usr/bin/env bash
# Summarize a tools/overnight-com-watch.sh run from its watcher log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_LOGDIR="${WATCH_LOGDIR:-$ROOT/log/overnight-com-watch}"
PERF_LOGDIR="${LOGDIR:-$ROOT/log/com-perf}"
FORMAT="${FORMAT:-markdown}"
PERF_EXPECTED_RATE_HZ="${PERF_EXPECTED_RATE_HZ:-auto}"
INPUT="${1:-}"

case "$FORMAT" in
  markdown|md|csv) ;;
  *)
    echo "ERROR: FORMAT must be markdown or csv, got '$FORMAT'" >&2
    exit 1
    ;;
esac

usage() {
  echo "Usage: FORMAT=markdown|csv tools/summarize-overnight-com-watch.sh <watch-log-or-tag-prefix>" >&2
  echo "       tools/summarize-overnight-com-watch.sh overnight_20260708_2300_setsid" >&2
}

if [ -z "$INPUT" ]; then
  usage
  exit 1
fi

if [ -f "$INPUT" ]; then
  WATCH_LOG="$INPUT"
else
  WATCH_LOG="$WATCH_LOGDIR/$INPUT.log"
fi

if [ ! -f "$WATCH_LOG" ]; then
  echo "ERROR: watcher log not found: $WATCH_LOG" >&2
  usage
  exit 1
fi

mapfile -t tags < <(
  sed -n 's/^.* smoke tag=\([^ ]*\).*$/\1/p' "$WATCH_LOG" |
    awk '!seen[$0]++'
)

if [ "${#tags[@]}" -eq 0 ]; then
  echo "ERROR: no smoke tags found in watcher log: $WATCH_LOG" >&2
  exit 1
fi

if [ "$FORMAT" = "csv" ]; then
  PERF_EXPECTED_RATE_HZ="$PERF_EXPECTED_RATE_HZ" \
    FORMAT=csv "$ROOT/tools/summarize-com-perf.sh" "${tags[@]}"
  exit 0
fi

perf_csv="$(PERF_EXPECTED_RATE_HZ="$PERF_EXPECTED_RATE_HZ" \
  FORMAT=csv "$ROOT/tools/summarize-com-perf.sh" "${tags[@]}")"

print_verdict_summary() {
  printf '%s\n' "$perf_csv" |
    awk -F, '
      NR == 1 {next}
      {
        total += 1
        verdict = $2
        reason = $3
        verdicts[verdict] += 1
        if (reason != "" && reason != "-") {
          split(reason, parts, ";")
          for (i in parts) {
            if (parts[i] != "") {
              reasons[parts[i]] += 1
            }
          }
        }
      }
      END {
        printf "- samples: %d\n", total
        printf "- PASS/WARN/FAIL/INFO: %d/%d/%d/%d\n", verdicts["PASS"] + 0, verdicts["WARN"] + 0, verdicts["FAIL"] + 0, verdicts["INFO"] + 0
        summary = ""
        for (reason in reasons) {
          item = reason "=" reasons[reason]
          if (summary == "") summary = item
          else summary = summary ", " item
        }
        if (summary == "") summary = "-"
        printf "- reasons: %s\n", summary
      }
    '
}

print_failure_events() {
  local tag cmd_log events any
  any=0

  for tag in "${tags[@]}"; do
    cmd_log="$PERF_LOGDIR/$tag.cmd.log"
    [ -f "$cmd_log" ] || continue
    events="$(awk '
      /LOST seq=/ {
        count += 1
        line = $0
        sub(/^.*node_com_cmd\]: /, "", line)
        if (count <= 3) {
          if (summary != "") summary = summary "; "
          summary = summary line
        }
      }
      END {
        if (count > 0) {
          if (count > 3) summary = summary "; ... (" count " lost events)"
          print summary
        }
      }
    ' "$cmd_log")"
    [ -n "$events" ] || continue
    printf -- "- %s: %s\n" "$tag" "$events"
    any=1
  done

  if [ "$any" -eq 0 ]; then
    echo "- none"
  fi
}

rel_watch_log="${WATCH_LOG#$ROOT/}"
echo "# Overnight Communication Watch Summary"
echo
echo "- watcher log: $rel_watch_log"
echo "- smoke samples: ${#tags[@]}"
echo "- generated: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo
echo "## Watch Events"
echo
echo '```text'
grep -E '^\[[^]]+\] (start|iteration=|sleep_s=|final_report|done)' "$WATCH_LOG" || true
echo '```'
echo
echo "## Verdict Summary"
echo
print_verdict_summary
echo
echo "## Failure Events"
echo
print_failure_events
echo
echo "## Communication Samples"
echo
PERF_EXPECTED_RATE_HZ="$PERF_EXPECTED_RATE_HZ" \
  "$ROOT/tools/summarize-com-perf.sh" "${tags[@]}"
