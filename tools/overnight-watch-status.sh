#!/usr/bin/env bash
# Summarize active overnight communication watcher processes and their logs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WATCH_LOGDIR="${WATCH_LOGDIR:-$ROOT/log/overnight-com-watch}"
NOW_EPOCH="${NOW_EPOCH:-$(date +%s)}"
PS_SNAPSHOT="${PS_SNAPSHOT:-}"

relpath() {
  local path="${1:-}"
  case "$path" in
    "$ROOT"/*) printf '%s\n' "${path#$ROOT/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}

sample_count() {
  local summary="$1"
  if [ ! -f "$summary" ]; then
    printf '0'
    return 0
  fi
  awk '/^- smoke samples:/ {print $4; found = 1; exit} END {if (!found) print 0}' "$summary"
}

file_age_s() {
  local file="$1"
  local mtime
  if [ ! -f "$file" ]; then
    printf 'unknown'
    return 0
  fi
  mtime="$(stat -c %Y "$file" 2>/dev/null || true)"
  if [ -z "$mtime" ]; then
    printf 'unknown'
  else
    printf '%s' "$((NOW_EPOCH - mtime))"
  fi
}

last_log_event() {
  local log="$1"
  if [ ! -f "$log" ]; then
    printf '-'
    return 0
  fi
  awk '/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} / {line = $0} END {print line ? line : "-"}' "$log"
}

next_wake_at() {
  local log="$1"
  if [ ! -f "$log" ]; then
    printf '-'
    return 0
  fi
  awk -F'wake_at=' '/sleep_s=/ {wake = $2} END {print wake ? wake : "-"}' "$log"
}

ps_input() {
  if [ -n "$PS_SNAPSHOT" ]; then
    cat "$PS_SNAPSHOT"
  else
    ps -eo pid=,etimes=,args= 2>/dev/null
  fi
}

found=0
while IFS= read -r line; do
  case "$line" in
    *tools/overnight-com-watch.sh*) ;;
    *) continue ;;
  esac
  pid="$(printf '%s\n' "$line" | awk '{print $1}')"
  elapsed_s="$(printf '%s\n' "$line" | awk '{print $2}')"
  cmd="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*[^[:space:]]+[[:space:]]+[^[:space:]]+[[:space:]]+//')"
  tag="$(printf '%s\n' "$cmd" | sed -E 's/^.*tools\/overnight-com-watch\.sh[[:space:]]+([^[:space:]]+).*$/\1/')"
  if [ "$tag" = "$cmd" ] || [ -z "$tag" ]; then
    tag="-"
  fi
  log="$WATCH_LOGDIR/$tag.log"
  summary="$WATCH_LOGDIR/$tag.summary.md"
  printf 'pid=%s elapsed_s=%s tag=%s samples=%s log=%s log_age_s=%s next_wake_at="%s" last_event="%s" cmd=%s\n' \
    "$pid" \
    "$elapsed_s" \
    "$tag" \
    "$(sample_count "$summary")" \
    "$(relpath "$log")" \
    "$(file_age_s "$log")" \
    "$(next_wake_at "$log")" \
    "$(last_log_event "$log")" \
    "$cmd"
  found=1
done < <(ps_input)

if [ "$found" -eq 0 ]; then
  echo 'none samples=0 log=- log_age_s=unknown next_wake_at="-" last_event="-"'
fi
