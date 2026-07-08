#!/usr/bin/env bash
# Summarize a tools/overnight-com-watch.sh run from its watcher log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_LOGDIR="${WATCH_LOGDIR:-$ROOT/log/overnight-com-watch}"
FORMAT="${FORMAT:-markdown}"
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
  FORMAT=csv "$ROOT/tools/summarize-com-perf.sh" "${tags[@]}"
  exit 0
fi

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
echo "## Communication Samples"
echo
"$ROOT/tools/summarize-com-perf.sh" "${tags[@]}"
