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
assert_contains "$actual" "CANDIDATE staircase_acceptance_contract" \
  "staircase acceptance contract candidate"
assert_contains "$actual" "qos_incompatibility=1" \
  "current QoS incompatibility is surfaced"

cat >"$TMPDIR/sample.wire.log" <<'EOF'
METRICS duration_s=10 total_serial_kbit_s=17.53 baud_util_pct=1.90 tx_serial_kbit_s=8.86 rx_serial_kbit_s=8.67
EOF
cat >"$TMPDIR/scheduler.csv" <<'EOF'
tag,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra
default,9.0,10.0,0,0
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
  "CANDIDATE pc_scheduler_lowest_max_observed tag=default p99_ms=9.000 max_ms=10.000 catchup_events=0 catchup_extra=0" \
  "synthetic scheduler lowest max candidate"
assert_contains "$synthetic" \
  "CANDIDATE qos_matching_required qos_incompatibility=0" \
  "synthetic QoS gate clear"
assert_contains "$synthetic" \
  "CANDIDATE staircase_acceptance_contract required=max_pc_catchup_events=0,max_pc_catchup_extra=0,rate_and_gap_defaults optional_wire=max_wire_baud_util_pct=30 adoption=run_after_staircase" \
  "synthetic staircase acceptance contract args"
assert_contains "$synthetic" \
  "tools/check-com-staircase-contract.py <metrics.csv> --max-pc-catchup-events 0 --max-pc-catchup-extra 0" \
  "synthetic runtime gate includes acceptance command"

auto_dir="$TMPDIR/auto"
mkdir -p "$auto_dir"
cat >"$auto_dir/old_200.metrics.csv" <<'EOF'
tag,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra
old_200_threads4_r1,5.2,6.0,0,0
EOF
cat >"$auto_dir/old_200.summary.log" <<'EOF'
profile cmd_rate_hz=200 cmd_catchup_max=0 qos=best_effort depth=1 tracking=sampled status_every_n=40 sample_window=1024 summary_period_s=5.0 link_health_period_s=5.0 startup_grace_s=3.0 executor_threads=0 require_core_metrics=0 require_health_pass=0 max_catchup_events=0 max_catchup_extra=0 isolate_ros_domain_per_case=auto resolved_isolate_ros_domain_per_case=1 ros_domain_base=0 run_seconds=30 warmup_seconds=5 hz_seconds=20
EOF
cat >"$auto_dir/new_1000.metrics.csv" <<'EOF'
tag,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra
new_1000_threads4_r1,1.1,5.0,0,0
EOF
cat >"$auto_dir/new_1000.summary.log" <<'EOF'
profile cmd_rate_hz=1000 cmd_catchup_max=0 qos=best_effort depth=1 tracking=sampled status_every_n=200 sample_window=1024 summary_period_s=5.0 link_health_period_s=5.0 startup_grace_s=3.0 executor_threads=0 require_core_metrics=0 require_health_pass=0 max_catchup_events=0 max_catchup_extra=0 isolate_ros_domain_per_case=auto resolved_isolate_ros_domain_per_case=1 ros_domain_base=0 run_seconds=20 warmup_seconds=3 hz_seconds=12
EOF
touch -t 202607090101 "$auto_dir/old_200.metrics.csv" "$auto_dir/old_200.summary.log"
touch -t 202607090102 "$auto_dir/new_1000.metrics.csv" "$auto_dir/new_1000.summary.log"

auto="$TMPDIR/auto.md"
"$ROOT/tools/recommend-communication-optimizations.py" \
  --wire-log "$TMPDIR/sample.wire.log" \
  --scheduler-logdir "$auto_dir" \
  --staircase-csv "$TMPDIR/staircase.csv" >"$auto"

assert_contains "$auto" \
  "scheduler CSV: $auto_dir/old_200.metrics.csv" \
  "auto scheduler selection skips newer non-200Hz profile"
assert_contains "$auto" \
  "exploratory scheduler CSV: $auto_dir/new_1000.metrics.csv" \
  "auto exploratory scheduler selection uses latest 1000Hz profile"
assert_contains "$auto" \
  "CANDIDATE pc_scheduler_best_observed tag=old_200_threads4_r1" \
  "auto scheduler recommendation uses latest matching 200Hz profile"
assert_contains "$auto" \
  "CANDIDATE pc_scheduler_1000hz_exploratory tag=new_1000_threads4_r1 p99_ms=1.100 max_ms=5.000 catchup_events=0 catchup_extra=0 adoption=explore_only_not_staircase_default" \
  "auto scheduler recommendation reports 1000Hz exploration separately"

echo "PASS: communication optimization recommendation tests"
