#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

write_header() {
  cat <<'EOF'
stage,verdict,reason,loop_hz,baud,timer_irq_priority,uart_read_poll_yields,executor_spin_timeout_us,pc_cmd_hz,qos,status_every_n,pc_launch_prefix,pc_executor_threads,status_hz,sampler_hz,target_rx_hz,p95_gap_s,p99_gap_s,max_gap_s,zero_gap_count,seq_rate_hz,seq_delta_avg,seq_delta_min,seq_delta_max,pc_target_rate_hz,pc_target_window_hz,pc_wire_gap_p95_ms,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra,wire_kbit_s,wire_baud_util_pct,tx_kbit_s,rx_kbit_s,lost,duplicate,inflight,qos_incompatibility
EOF
}

write_row() {
  local loop_hz="$1"
  local baud="$2"
  local suffix="${3:-}"
  local verdict="${4:-PASS}"
  local reason="${5:--}"
  local qos_bad="${6:-0}"
  local catchup_events="${7:-0}"
  local catchup_extra="${8:-0}"
  local target_rx_hz="${9:-200.0}"
  local pc_target_window_hz="${10:-200.0}"
  local pc_gap_p99_ms="${11:-6.0}"
  local pc_gap_max_ms="${12:-8.0}"
  printf 'latest_%shz_%sbaud_irqp4_poll0_spin1000us_200hz_be_n40%s,%s,%s,%s,%s,4,0,1000,200,best_effort,40,taskset -c 2,2,5,5,%s,0.050,0.060,0.080,0,5,40,40,40,200.0,%s,5.0,%s,%s,%s,%s,94.0,10.2,48,46,0,0,0,%s\n' \
    "$loop_hz" "$baud" "$suffix" "$verdict" "$reason" "$loop_hz" "$baud" \
    "$target_rx_hz" "$pc_target_window_hz" "$pc_gap_p99_ms" "$pc_gap_max_ms" \
    "$catchup_events" "$catchup_extra" "$qos_bad"
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
assert_contains "$out" "target_rx_hz_range=180..220" \
  "default target receive rate range"
assert_contains "$out" "pc_wire_gap_p99_ms_max=20" \
  "default PC p99 gap gate"
assert_contains "$out" "max_pc_catchup_events=0" "default catch-up event gate"
assert_contains "$out" "max_pc_catchup_extra=0" "default catch-up extra gate"

out="$("$ROOT/tools/check-com-staircase-contract.py" "$pass_csv" --pc-executor-threads 2)"
assert_contains "$out" "PASS com_staircase_contract" \
  "passing contract with executor thread filter"

out="$("$ROOT/tools/check-com-staircase-contract.py" "$pass_csv" --executor-spin-timeout-us 1000)"
assert_contains "$out" "PASS com_staircase_contract" \
  "passing contract with executor spin timeout filter"

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$pass_csv" --pc-executor-threads 0 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: wrong executor thread filter should fail" >&2
  exit 1
fi
assert_contains "$out" "pc_executor_threads=0" \
  "executor thread filter labels missing stages"

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$pass_csv" --executor-spin-timeout-us 100 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: wrong executor spin timeout filter should fail" >&2
  exit 1
fi
assert_contains "$out" "executor_spin_timeout_us=100" \
  "executor spin timeout filter labels missing stages"

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

burst_csv="$TMPDIR/burst.csv"
write_header >"$burst_csv"
for loop_hz in 1000 2000 5000 10000; do
  for baud in 921600 2000000; do
    if [ "$loop_hz" = "10000" ] && [ "$baud" = "2000000" ]; then
      write_row "$loop_hz" "$baud" "" "PASS" "-" "0" "1" "3" >>"$burst_csv"
    else
      write_row "$loop_hz" "$baud" >>"$burst_csv"
    fi
  done
done

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$burst_csv" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: burst catch-up matrix should fail by default" >&2
  exit 1
fi
assert_contains "$out" "pc_cmd_catchup_events=1" \
  "catch-up event detail"
assert_contains "$out" "pc_cmd_catchup_extra=3" \
  "catch-up extra detail"

out="$("$ROOT/tools/check-com-staircase-contract.py" "$burst_csv" \
  --max-pc-catchup-events 1 --max-pc-catchup-extra 3)"
assert_contains "$out" "PASS com_staircase_contract" \
  "catch-up gate can be explicitly relaxed"
assert_contains "$out" "max_pc_catchup_extra=3" \
  "relaxed catch-up gate is reported"

slow_rx_csv="$TMPDIR/slow_rx.csv"
write_header >"$slow_rx_csv"
for loop_hz in 1000 2000 5000 10000; do
  for baud in 921600 2000000; do
    if [ "$loop_hz" = "5000" ] && [ "$baud" = "921600" ]; then
      write_row "$loop_hz" "$baud" "" "PASS" "-" "0" "0" "0" "150.0" "200.0" \
        "6.0" "8.0" >>"$slow_rx_csv"
    else
      write_row "$loop_hz" "$baud" >>"$slow_rx_csv"
    fi
  done
done

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$slow_rx_csv" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: slow target receive rate should fail by default" >&2
  exit 1
fi
assert_contains "$out" "target_rx_hz=150.0" \
  "slow target receive rate detail"

gap_csv="$TMPDIR/gap.csv"
write_header >"$gap_csv"
for loop_hz in 1000 2000 5000 10000; do
  for baud in 921600 2000000; do
    if [ "$loop_hz" = "2000" ] && [ "$baud" = "2000000" ]; then
      write_row "$loop_hz" "$baud" "" "PASS" "-" "0" "0" "0" "200.0" "200.0" \
        "30.0" "60.0" >>"$gap_csv"
    else
      write_row "$loop_hz" "$baud" >>"$gap_csv"
    fi
  done
done

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$gap_csv" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: high PC wire gap should fail by default" >&2
  exit 1
fi
assert_contains "$out" "pc_wire_gap_p99_ms=30.0" \
  "high PC p99 gap detail"
assert_contains "$out" "pc_wire_gap_max_ms=60.0" \
  "high PC max gap detail"

out="$("$ROOT/tools/check-com-staircase-contract.py" "$gap_csv" \
  --max-pc-p99-gap-ratio 6 --max-pc-max-gap-ratio 12)"
assert_contains "$out" "PASS com_staircase_contract" \
  "PC gap gates can be explicitly relaxed"
assert_contains "$out" "pc_wire_gap_p99_ms_max=30" \
  "relaxed PC p99 gap gate is reported"

set +e
out="$("$ROOT/tools/check-com-staircase-contract.py" "$pass_csv" \
  --expected-pc-cmd-hz 0 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then
  echo "FAIL: invalid expected PC rate should fail" >&2
  exit 1
fi
assert_contains "$out" "invalid_expected_pc_cmd_hz" \
  "invalid expected PC rate reason"

echo "PASS: communication staircase contract tests"
