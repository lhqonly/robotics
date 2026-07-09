#!/usr/bin/env bash
# Offline regression tests for tools/check-com-perf-contract.sh.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

mkdir -p "$TMPDIR/com-perf"

write_tag() {
  local tag="$1"
  local target_window_hz="$2"
  local p99_ms="$3"
  local max_ms="$4"
  local lost="$5"
  local duplicate="$6"
  local sampler_hz="$7"

  printf '%s\n' \
    "[node_com_cmd] link-health summary: sent=100 matched=100 lost=$lost duplicate=$duplicate inflight=0 wire_rate_hz=$target_window_hz target_rate_hz=200.000 target_window_hz=$target_window_hz wire_gap_p99_ms=$p99_ms wire_gap_max_ms=$max_ms" \
    >"$TMPDIR/com-perf/$tag.cmd.log"
  printf '%s\n' \
    "status_sampler: count=50 rate_hz=$sampler_hz seq_rate_hz=$sampler_hz seq_delta_avg=1 seq_delta_min=1 seq_delta_max=1 p95_gap_s=0.005 p99_gap_s=0.006 max_gap_s=0.007 zero_gap_count=0" \
    >"$TMPDIR/com-perf/$tag.sampler.log"
}

write_tag pass200 200.000 12.0 30.0 0 0 200.000
write_tag slow_gap 200.000 21.0 30.0 0 0 200.000
write_tag lost_one 200.000 12.0 30.0 1 0 200.000
write_tag status40 200.000 12.0 30.0 0 0 5.000
write_tag qos_bad 200.000 12.0 30.0 0 0 200.000
printf '%s\n' \
  "[node_com_cmd] [WARN] [1.0] [node_com_cmd]: New subscription discovered on topic '/com/tp_cmd_heartbeat', requesting incompatible QoS. No messages will be sent to it. Last incompatible policy: RELIABILITY" \
  >>"$TMPDIR/com-perf/qos_bad.cmd.log"
printf '%s\n' \
  "[node_com_cmd] link-health summary: sent=0 matched=0 lost=0 duplicate=0 inflight=0 wire_rate_hz=200.000 target_rate_hz=0.000 target_window_hz=0.000 wire_gap_p99_ms=10.0 wire_gap_max_ms=30.0" \
  "[node_com_cmd] [WARN] [1.0] [node_com_cmd]: New subscription discovered on topic '/com/tp_cmd_heartbeat', requesting incompatible QoS. No messages will be sent to it. Last incompatible policy: RELIABILITY" \
  >"$TMPDIR/com-perf/qos_target_zero.cmd.log"
printf '%s\n' \
  "status_sampler: count=0 rate_hz=0.000 seq_rate_hz=0.000 seq_delta_avg=0 seq_delta_min=0 seq_delta_max=0 p95_gap_s=0.000 p99_gap_s=0.000 max_gap_s=0.000 zero_gap_count=0" \
  >"$TMPDIR/com-perf/qos_target_zero.sampler.log"

pass_out="$(LOGDIR="$TMPDIR/com-perf" EXPECTED_CMD_RATE_HZ=200 \
  "$ROOT/tools/check-com-perf-contract.sh" pass200)"
if ! grep -Fq 'PASS tag=pass200' <<<"$pass_out"; then
  echo "ERROR: expected pass200 to pass" >&2
  echo "$pass_out" >&2
  exit 1
fi

if LOGDIR="$TMPDIR/com-perf" EXPECTED_CMD_RATE_HZ=200 \
    "$ROOT/tools/check-com-perf-contract.sh" slow_gap >"$TMPDIR/contract.out" 2>&1; then
  echo "ERROR: expected slow_gap to fail" >&2
  cat "$TMPDIR/contract.out" >&2
  exit 1
fi
grep -Fq 'pc_wire_gap_p99_high' "$TMPDIR/contract.out"

if LOGDIR="$TMPDIR/com-perf" EXPECTED_CMD_RATE_HZ=200 \
    "$ROOT/tools/check-com-perf-contract.sh" lost_one >"$TMPDIR/contract.out" 2>&1; then
  echo "ERROR: expected lost_one to fail" >&2
  cat "$TMPDIR/contract.out" >&2
  exit 1
fi
grep -Fq 'lost_high' "$TMPDIR/contract.out"

if LOGDIR="$TMPDIR/com-perf" EXPECTED_CMD_RATE_HZ=200 \
    "$ROOT/tools/check-com-perf-contract.sh" qos_bad >"$TMPDIR/contract.out" 2>&1; then
  echo "ERROR: expected qos_bad to fail" >&2
  cat "$TMPDIR/contract.out" >&2
  exit 1
fi
grep -Fq 'qos_incompatible' "$TMPDIR/contract.out"
grep -Fq 'Last incompatible policy: RELIABILITY' "$TMPDIR/contract.out"

if LOGDIR="$TMPDIR/com-perf" STATUS_EVERY_N=40 \
    "$ROOT/tools/check-com-perf-contract.sh" qos_target_zero >"$TMPDIR/contract.out" 2>&1; then
  echo "ERROR: expected qos_target_zero to fail" >&2
  cat "$TMPDIR/contract.out" >&2
  exit 1
fi
grep -Fq 'qos_incompatible' "$TMPDIR/contract.out"
grep -Fq 'pc_target_rate_out_of_band' "$TMPDIR/contract.out"
grep -Fq 'expected_cmd_hz=200.000' "$TMPDIR/contract.out"
if grep -Fq 'division by zero' "$TMPDIR/contract.out"; then
  echo "ERROR: qos_target_zero triggered division by zero" >&2
  cat "$TMPDIR/contract.out" >&2
  exit 1
fi

status40_out="$(LOGDIR="$TMPDIR/com-perf" EXPECTED_CMD_RATE_HZ=200 STATUS_EVERY_N=40 \
  "$ROOT/tools/check-com-perf-contract.sh" status40)"
if ! grep -Fq 'expected_status_hz=5.000000' <<<"$status40_out"; then
  echo "ERROR: expected status40 to use decimated status rate" >&2
  echo "$status40_out" >&2
  exit 1
fi

echo "PASS: communication performance contract tests"
