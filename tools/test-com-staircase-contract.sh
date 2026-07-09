#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

write_header() {
  cat <<'EOF'
stage,verdict,reason,loop_hz,baud,timer_irq_priority,uart_read_poll_yields,executor_spin_timeout_us,pc_cmd_hz,qos,status_every_n,pc_launch_prefix,status_hz,sampler_hz,target_rx_hz,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,pc_target_rate_hz,pc_target_window_hz,pc_wire_gap_p95_ms,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,wire_kbit_s,wire_baud_util_pct,tx_kbit_s,rx_kbit_s,lost,duplicate,inflight,qos_incompatibility
EOF
}

write_row() {
  local loop_hz="$1"
  local baud="$2"
  local suffix="${3:-}"
  local verdict="${4:-PASS}"
  local reason="${5:--}"
  local qos_bad="${6:-0}"
  printf 'latest_%shz_%sbaud_irqp4_poll0_spin1000us_200hz_be_n40%s,%s,%s,%s,%s,4,0,1000,200,best_effort,40,taskset -c 2,5,5,200.0,0.050,0.060,0.080,0,5,40,40,40,200.0,200.0,5.0,6.0,8.0,94.0,10.2,48,46,0,0,0,%s\n' \
    "$loop_hz" "$baud" "$suffix" "$verdict" "$reason" "$loop_hz" "$baud" "$qos_bad"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! grep -Fq -- "$needle" <<<"$haystack"; then
    echo "FAIL: $label missing '$needle'" >&2
    echo "output:" >&2
    printf '%s\n' "$haystack" >&2
    exit 1
  fi
}

pass_csv="$TMPDIR/pass.csv"
write_header >"$pass_csv"
for loop_hz in 1000 2000 5000 10000; do
  for baud in 921600 2000000; do
    write_row "$loop_hz" "$baud" >>"$pass_csv"
  done
done

out="$("$ROOT/tools/check-com-staircase-contract.py" "$pass_csv")"
assert_contains "$out" "PASS com_staircase_contract" "passing contract"
assert_contains "$out" "passed=8/8" "passing stage count"

missing_csv="$TMPDIR/missing.csv"
write_header >"$missing_csv"
for loop_hz in 1000 2000 5000; do
  for baud in 921600 2000000; do
    write_row "$loop_hz" "$baud" >>"$missing_csv"
  done
done

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$missing_csv" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: missing matrix should fail" >&2
  exit 1
fi
assert_contains "$out" "missing_required_stage(loop_hz=10000,baud=921600)" \
  "missing 10k 921600 stage"

qos_csv="$TMPDIR/qos.csv"
write_header >"$qos_csv"
for loop_hz in 1000 2000 5000 10000; do
  for baud in 921600 2000000; do
    if [ "$loop_hz" = "10000" ] && [ "$baud" = "2000000" ]; then
      write_row "$loop_hz" "$baud" "" "FAIL" "qos_incompatible" "1" >>"$qos_csv"
    else
      write_row "$loop_hz" "$baud" >>"$qos_csv"
    fi
  done
done

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$qos_csv" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: QoS-bad matrix should fail" >&2
  exit 1
fi
assert_contains "$out" "no_passing_stage(loop_hz=10000,baud=2000000" \
  "QoS-bad stage failure"
assert_contains "$out" "qos_incompatibility=1" \
  "QoS incompatibility detail"

echo "PASS: communication staircase contract tests"
