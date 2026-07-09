#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'if [ -n "${live_pid:-}" ]; then kill "$live_pid" 2>/dev/null || true; fi; rm -rf "$TMPDIR"' EXIT

assert_contains() {
  local file="$1"
  local needle="$2"
  local message="$3"
  if ! grep -Fq -- "$needle" "$file"; then
    echo "FAIL: $message" >&2
    echo "missing: $needle" >&2
    echo "--- output ---" >&2
    cat "$file" >&2
    exit 1
  fi
}

bash -n "$ROOT/tools/start-overnight-com-watch.sh"
bash -n "$ROOT/tools/overnight-com-watch.sh"

assert_contains "$ROOT/tools/overnight-com-watch.sh" \
  'SERIAL_LOCK_WAIT_SECONDS="${SERIAL_LOCK_WAIT_SECONDS:-120}"' \
  "overnight watcher waits for serial lock by default"
assert_contains "$ROOT/tools/overnight-com-watch.sh" \
  'SERIAL_LOCK_WAIT_SECONDS="$SERIAL_LOCK_WAIT_SECONDS"' \
  "overnight watcher passes serial lock wait to run-com-perf"

dry_out="$TMPDIR/dry.txt"
DRY_RUN=1 LOGDIR="$TMPDIR/logs" \
  "$ROOT/tools/start-overnight-com-watch.sh" test_watch >"$dry_out"
assert_contains "$dry_out" "DRY_RUN setsid $ROOT/tools/overnight-com-watch.sh test_watch" \
  "dry run prints detached command"
assert_contains "$dry_out" "pidfile=$TMPDIR/logs/test_watch.pid" \
  "dry run prints pidfile"
assert_contains "$dry_out" "summary_md=$TMPDIR/logs/test_watch.summary.md" \
  "dry run prints summary path"

fake_watch="$TMPDIR/fake-watch.sh"
cat >"$fake_watch" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
tag="$1"
echo "fake start $tag"
sleep 60
EOF
chmod +x "$fake_watch"

start_out="$TMPDIR/start.txt"
LOGDIR="$TMPDIR/live" WATCH_CMD="$fake_watch" STARTUP_WAIT_SECONDS=0 \
  ALLOW_MULTIPLE=1 \
  "$ROOT/tools/start-overnight-com-watch.sh" live_watch >"$start_out"
assert_contains "$start_out" "started pid=" \
  "launcher reports started pid"
assert_contains "$start_out" "watch_log=$TMPDIR/live/live_watch.log" \
  "launcher reports watch log"

live_pid="$(sed -n 's/^started pid=//p' "$start_out")"
if ! ps -p "$live_pid" >/dev/null 2>&1; then
  echo "FAIL: launched fake watcher is not running" >&2
  cat "$start_out" >&2
  exit 1
fi

again_out="$TMPDIR/again.txt"
LOGDIR="$TMPDIR/live" WATCH_CMD="$fake_watch" STARTUP_WAIT_SECONDS=0 \
  "$ROOT/tools/start-overnight-com-watch.sh" live_watch >"$again_out"
assert_contains "$again_out" "already_running pid=$live_pid" \
  "launcher detects existing pidfile process"

echo "PASS: overnight watcher launcher tests"
