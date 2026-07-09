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

bash -n "$ROOT/tools/check-overnight-watch-contract.sh"

watch_log="$TMPDIR/night.log"
: >"$watch_log"

summary="$TMPDIR/summary.sh"
cat >"$summary" <<'EOF'
#!/usr/bin/env bash
cat <<'CSV'
tag,verdict,reason,status_hz,sampler_hz,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,pc_wire_rate_hz,pc_target_rate_hz,pc_target_window_hz,pc_wire_gap_p95_ms,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra,wire_kbit_s,baud_util_pct,lost,duplicate,inflight
night_001,PASS,-,20,20,20,1,1,1,0.05,0.05,0.06,0,20,20,20,50,55,70,0,0,NA,NA,0,0,1
night_002,PASS,-,20,20,20,1,1,1,0.05,0.05,0.06,0,20,20,20,50,55,70,0,0,NA,NA,0,0,1
CSV
EOF
chmod +x "$summary"

out="$TMPDIR/pass.txt"
SUMMARY_CMD="$summary" "$ROOT/tools/check-overnight-watch-contract.sh" "$watch_log" >"$out"
assert_contains "$out" "PASS overnight_watch_contract" \
  "passing contract"
assert_contains "$out" "samples=2" \
  "passing sample count"

set +e
MIN_SAMPLES=3 SUMMARY_CMD="$summary" \
  "$ROOT/tools/check-overnight-watch-contract.sh" "$watch_log" >"$TMPDIR/fail_samples.txt"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: min-samples contract should fail" >&2
  exit 1
fi
assert_contains "$TMPDIR/fail_samples.txt" "samples_low" \
  "min sample failure"

bad_summary="$TMPDIR/bad-summary.sh"
cat >"$bad_summary" <<'EOF'
#!/usr/bin/env bash
cat <<'CSV'
tag,verdict,reason,status_hz,sampler_hz,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,pc_wire_rate_hz,pc_target_rate_hz,pc_target_window_hz,pc_wire_gap_p95_ms,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra,wire_kbit_s,baud_util_pct,lost,duplicate,inflight
night_001,PASS,-,20,20,20,1,1,1,0.05,0.05,0.06,0,20,20,20,50,55,70,0,0,NA,NA,0,0,1
night_002,FAIL,lost_nonzero,20,20,20,1,1,1,0.05,0.05,0.06,0,20,20,20,50,55,70,0,0,NA,NA,1,0,1
CSV
EOF
chmod +x "$bad_summary"

set +e
SUMMARY_CMD="$bad_summary" "$ROOT/tools/check-overnight-watch-contract.sh" "$watch_log" >"$TMPDIR/fail_lost.txt"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: lost/fail contract should fail" >&2
  exit 1
fi
assert_contains "$TMPDIR/fail_lost.txt" "fails_high" \
  "fail verdict failure"
assert_contains "$TMPDIR/fail_lost.txt" "lost_high" \
  "lost failure"

echo "PASS: overnight watcher contract tests"
