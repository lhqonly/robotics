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
    echo "output:" >&2
    cat "$file" >&2
    exit 1
  fi
}

actual="$TMPDIR/actual.md"
"$ROOT/tools/recommend-communication-optimizations.py" >"$actual"
assert_contains "$actual" "# Communication Optimization Recommendations" \
  "communication recommendation title"
assert_contains "$actual" "RECOMMENDATION control_link=pc_200hz_latest_target_mcu_status_decimated" \
  "default communication recommendation"
assert_contains "$actual" "CANDIDATE wire_budget_200hz_status40_921600" \
  "wire budget candidate"
assert_contains "$actual" "CANDIDATE baud_2000000_for_200hz_status40" \
  "2Mbps candidate"
assert_contains "$actual" "CANDIDATE qos_matching_required" \
  "QoS gate candidate"
assert_contains "$actual" "qos_incompatibility=1" \
  "current QoS incompatibility is surfaced"

cat >"$TMPDIR/sample.wire.log" <<'EOF'
METRICS duration_s=10 total_serial_kbit_s=17.53 baud_util_pct=1.90 tx_serial_kbit_s=8.86 rx_serial_kbit_s=8.67
EOF
cat >"$TMPDIR/scheduler.csv" <<'EOF'
tag,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra
default,11.0,22.0,3,5
taskset_cpu2,8.0,12.0,0,0
EOF
cat >"$TMPDIR/staircase.csv" <<'EOF'
stage,qos_incompatibility
probe,0
EOF

synthetic="$TMPDIR/synthetic.md"
"$ROOT/tools/recommend-communication-optimizations.py" \
  --wire-log "$TMPDIR/sample.wire.log" \
  --scheduler-csv "$TMPDIR/scheduler.csv" \
  --staircase-csv "$TMPDIR/staircase.csv" >"$synthetic"

assert_contains "$synthetic" \
  "CANDIDATE wire_budget_200hz_status40_921600 util_pct=9.85 total_kbit_s=90.77" \
  "synthetic 200Hz/status40 921600 budget"
assert_contains "$synthetic" \
  "CANDIDATE baud_2000000_for_200hz_status40 util_pct=4.54 cmd_wire_ms=0.222 wire_time_reduction_pct=53.9" \
  "synthetic 2Mbps benefit"
assert_contains "$synthetic" \
  "CANDIDATE avoid_reliable_full_echo_200hz projected_util_pct=19.02" \
  "synthetic full-echo warning"
assert_contains "$synthetic" \
  "CANDIDATE pc_scheduler_best_observed tag=taskset_cpu2 p99_ms=8.000 max_ms=12.000 catchup_events=0 catchup_extra=0" \
  "synthetic scheduler best candidate"
assert_contains "$synthetic" \
  "CANDIDATE qos_matching_required qos_incompatibility=0" \
  "synthetic QoS gate clear"

echo "PASS: communication optimization recommendation tests"
