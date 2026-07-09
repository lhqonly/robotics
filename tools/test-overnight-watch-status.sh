#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

assert_contains() {
  local file="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $label missing '$needle'" >&2
    echo "--- output ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

bash -n "$ROOT/tools/overnight-watch-status.sh"

logdir="$TMPDIR/watch"
mkdir -p "$logdir"
cat >"$TMPDIR/ps.txt" <<EOF
123 456 bash $ROOT/tools/overnight-com-watch.sh night_a
EOF
cat >"$logdir/night_a.log" <<'EOF'
[2026-07-09 13:01:00 +08] start tag_prefix=night_a end_at=tomorrow 09:00 interval_s=1800 wire_every_n=0 pc_launch_prefix=taskset -c 2
[2026-07-09 13:02:00 +08] iteration=1 smoke=ok
[2026-07-09 13:02:20 +08] summary=ok markdown=log/overnight-com-watch/night_a.summary.md csv=log/overnight-com-watch/night_a.summary.csv
[2026-07-09 13:02:20 +08] sleep_s=1800 wake_at=2026-07-09 13:32:20 +08
EOF
cat >"$logdir/night_a.summary.md" <<'EOF'
# Overnight Communication Watch Summary

- smoke samples: 1
EOF

out="$TMPDIR/out.txt"
WATCH_LOGDIR="$logdir" PS_SNAPSHOT="$TMPDIR/ps.txt" NOW_EPOCH=1783574000 \
  "$ROOT/tools/overnight-watch-status.sh" >"$out"
assert_contains "$out" "pid=123 elapsed_s=456 tag=night_a samples=1" \
  "active watcher identity"
assert_contains "$out" "freshness=fresh" \
  "fresh watcher is marked fresh"
assert_contains "$out" "sleep_s=1800" \
  "sleep interval is parsed"
assert_contains "$out" "next_wake_at=\"2026-07-09 13:32:20 +08\"" \
  "next wake is parsed"
assert_contains "$out" "last_event=\"[2026-07-09 13:02:20 +08] sleep_s=1800 wake_at=2026-07-09 13:32:20 +08\"" \
  "last event is parsed"
assert_contains "$out" "cmd=bash $ROOT/tools/overnight-com-watch.sh night_a" \
  "command is reported"

empty="$TMPDIR/empty.txt"
: >"$TMPDIR/empty-ps.txt"
WATCH_LOGDIR="$logdir" PS_SNAPSHOT="$TMPDIR/empty-ps.txt" \
  "$ROOT/tools/overnight-watch-status.sh" >"$empty"
assert_contains "$empty" "none" \
  "no active watcher fallback"

stale="$TMPDIR/stale.txt"
WATCH_LOGDIR="$logdir" PS_SNAPSHOT="$TMPDIR/ps.txt" NOW_EPOCH=1783577000 \
  WATCH_STALE_GRACE_SECONDS=60 \
  "$ROOT/tools/overnight-watch-status.sh" >"$stale"
assert_contains "$stale" "freshness=stale" \
  "stale watcher is marked stale"

echo "PASS: overnight watcher status tests"
