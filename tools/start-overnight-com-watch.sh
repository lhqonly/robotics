#!/usr/bin/env bash
# Start overnight-com-watch in a detached session with a pidfile and startup check.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG_PREFIX="${1:-overnight_auto_$(date +%Y%m%d_%H%M)}"
LOGDIR="${LOGDIR:-$ROOT/log/overnight-com-watch}"
WATCH_CMD="${WATCH_CMD:-$ROOT/tools/overnight-com-watch.sh}"
STARTUP_WAIT_SECONDS="${STARTUP_WAIT_SECONDS:-3}"
DRY_RUN="${DRY_RUN:-0}"
ALLOW_MULTIPLE="${ALLOW_MULTIPLE:-0}"

mkdir -p "$LOGDIR"

PIDFILE="${PIDFILE:-$LOGDIR/$TAG_PREFIX.pid}"
RUNNER_LOG="${RUNNER_LOG:-$LOGDIR/$TAG_PREFIX.runner.log}"
WATCH_LOG="$LOGDIR/$TAG_PREFIX.log"
SUMMARY_MD="$LOGDIR/$TAG_PREFIX.summary.md"
SUMMARY_CSV="$LOGDIR/$TAG_PREFIX.summary.csv"

relpath() {
  local path="$1"
  case "$path" in
    "$ROOT"/*) printf '%s\n' "${path#$ROOT/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

print_paths() {
  printf 'tag=%s\n' "$TAG_PREFIX"
  printf 'pidfile=%s\n' "$(relpath "$PIDFILE")"
  printf 'runner_log=%s\n' "$(relpath "$RUNNER_LOG")"
  printf 'watch_log=%s\n' "$(relpath "$WATCH_LOG")"
  printf 'summary_md=%s\n' "$(relpath "$SUMMARY_MD")"
  printf 'summary_csv=%s\n' "$(relpath "$SUMMARY_CSV")"
}

active_watcher() {
  ps -eo pid=,args= 2>/dev/null |
    awk '
      /tools\/overnight-com-watch\.sh/ {
        pid = $1
        $1 = ""
        sub(/^[[:space:]]+/, "")
        cmd = $0
        tag = cmd
        sub(/^.*tools\/overnight-com-watch\.sh[[:space:]]+/, "", tag)
        sub(/[[:space:]].*$/, "", tag)
        if (tag == cmd || tag == "") {
          tag = "-"
        }
        printf("pid=%s tag=%s cmd=%s\n", pid, tag, cmd)
        exit
      }
    ' || true
}

if [ ! -x "$WATCH_CMD" ]; then
  echo "ERROR: WATCH_CMD is not executable: $WATCH_CMD" >&2
  exit 2
fi

if [ -s "$PIDFILE" ]; then
  existing_pid="$(sed -n '1p' "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$existing_pid" ] && ps -p "$existing_pid" >/dev/null 2>&1; then
    echo "already_running pid=$existing_pid"
    print_paths
    exit 0
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  echo "DRY_RUN setsid $WATCH_CMD $TAG_PREFIX > $RUNNER_LOG 2>&1 < /dev/null"
  print_paths
  exit 0
fi

if [ "$ALLOW_MULTIPLE" != "1" ]; then
  active="$(active_watcher)"
  if [ -n "$active" ]; then
    echo "already_running $active"
    print_paths
    exit 0
  fi
fi

setsid "$WATCH_CMD" "$TAG_PREFIX" >"$RUNNER_LOG" 2>&1 < /dev/null &
watch_pid="$!"
printf '%s\n' "$watch_pid" >"$PIDFILE"

sleep "$STARTUP_WAIT_SECONDS"
if ps -p "$watch_pid" >/dev/null 2>&1; then
  printf 'started pid=%s\n' "$watch_pid"
  print_paths
  exit 0
fi

echo "ERROR: watcher exited during startup pid=$watch_pid" >&2
print_paths >&2
if [ -s "$RUNNER_LOG" ]; then
  echo "--- runner log tail ---" >&2
  tail -n 40 "$RUNNER_LOG" >&2 || true
fi
exit 1
