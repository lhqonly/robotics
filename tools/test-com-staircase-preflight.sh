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

bash -n "$ROOT/tools/com-staircase-preflight.sh"

fake_recommend="$TMPDIR/fake-recommend.sh"
cat >"$fake_recommend" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${FORMAT:-markdown}" in
  cases)
    printf '%s\n' 'default|' 'threads4||4'
    ;;
  contract_args)
    printf '%s\n' '--max-pc-catchup-events 0 --max-pc-catchup-extra 0'
    ;;
  *)
    echo "fake recommendation"
    ;;
esac
EOF
chmod +x "$fake_recommend"

fake_watch="$TMPDIR/fake-watch.sh"
cat >"$fake_watch" <<'EOF'
#!/usr/bin/env bash
echo 'pid=123 elapsed_s=10 tag=night samples=2 freshness=fresh log=log/overnight-com-watch/night.log log_age_s=5 sleep_s=1800 next_wake_at="2026-07-09 14:00:00 +08" last_event="ok"'
EOF
chmod +x "$fake_watch"

ok_out="$TMPDIR/ok.txt"
SWD_STATUS_OVERRIDE=ok RECOMMEND_CMD="$fake_recommend" WATCH_STATUS_CMD="$fake_watch" \
  "$ROOT/tools/com-staircase-preflight.sh" >"$ok_out"
assert_contains "$ok_out" "PREFLIGHT_SWD_STATUS=ok" \
  "SWD OK status"
assert_contains "$ok_out" "PREFLIGHT_RECOMMEND_STATUS=ok" \
  "recommendation OK"
assert_contains "$ok_out" "PREFLIGHT_STAIRCASE_CASE threads4||4" \
  "recommended case is listed"
assert_contains "$ok_out" "PREFLIGHT_CONTRACT_ARGS=--max-pc-catchup-events 0 --max-pc-catchup-extra 0" \
  "contract args listed"
assert_contains "$ok_out" "PREFLIGHT_READY=yes" \
  "preflight ready when SWD and recommendation are OK"
assert_contains "$ok_out" "PREFLIGHT_NEXT_ACTION=run_recommended_staircase_then_contract" \
  "ready next action"
assert_contains "$ok_out" "PREFLIGHT_WATCH pid=123" \
  "watch status included"

bad_out="$TMPDIR/bad.txt"
SWD_STATUS_OVERRIDE=bad_unknown_target RECOMMEND_CMD="$fake_recommend" WATCH_STATUS_CMD="$fake_watch" \
  "$ROOT/tools/com-staircase-preflight.sh" >"$bad_out"
assert_contains "$bad_out" "PREFLIGHT_READY=no" \
  "preflight not ready when SWD is bad"
assert_contains "$bad_out" "PREFLIGHT_NEXT_ACTION=recover_swd_keep_noflash_watch_running" \
  "SWD recovery next action"

missing_out="$TMPDIR/missing.txt"
SWD_STATUS_OVERRIDE=ok RECOMMEND_CMD="$TMPDIR/missing-recommend" WATCH_STATUS_CMD="$fake_watch" \
  "$ROOT/tools/com-staircase-preflight.sh" >"$missing_out"
assert_contains "$missing_out" "PREFLIGHT_RECOMMEND_STATUS=missing" \
  "missing recommendation is reported"
assert_contains "$missing_out" "PREFLIGHT_NEXT_ACTION=run_pc_scheduler_sweep_before_staircase" \
  "scheduler sweep next action"

echo "PASS: communication staircase preflight tests"
