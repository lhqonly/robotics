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
    echo "FAIL: $label missing '$needle' in $file" >&2
    cat "$file" >&2
    exit 1
  fi
}

bash -n "$ROOT/tools/recommend-staircase-command.sh"

cat >"$TMPDIR/scheduler.metrics.csv" <<'EOF'
tag,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra
demo_default_r1,8.400,17.000,0,0
demo_threads2_r1,5.900,16.000,0,0
demo_taskset_threads2_r1,6.800,31.000,0,0
EOF
cat >"$TMPDIR/scheduler.summary.log" <<'EOF'
START label=default run=1 tag=demo_default_r1 prefix=none executor_threads=0 stage_ros_domain_id=0
START label=threads2 run=1 tag=demo_threads2_r1 prefix=none executor_threads=2 stage_ros_domain_id=1
START label=taskset_threads2 run=1 tag=demo_taskset_threads2_r1 prefix=taskset -c 2 executor_threads=2 stage_ros_domain_id=2
EOF

out="$TMPDIR/out.md"
SCHEDULER_CSV="$TMPDIR/scheduler.metrics.csv" \
  SUMMARY="$TMPDIR/scheduler.summary.log" \
  TAG_PREFIX="staircase_demo" \
  "$ROOT/tools/recommend-staircase-command.sh" >"$out"

assert_contains "$out" "# Recommended Communication Staircase Command" \
  "title"
assert_contains "$out" "selected scheduler tag: demo_threads2_r1" \
  "best p99 scheduler candidate"
assert_contains "$out" "selected case: label=threads2 prefix=none executor_threads=2" \
  "selected case fields"
assert_contains "$out" "STAIRCASE_BAUDS='921600 2000000'" \
  "default baud matrix"
assert_contains "$out" "STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US='1000 100'" \
  "default spin timeout comparison"
assert_contains "$out" "'default|'" \
  "default PC case included"
assert_contains "$out" "'threads2||2'" \
  "selected executor thread case included"
assert_contains "$out" "tools/run-com-staircase.sh 'staircase_demo'" \
  "staircase command tag"

cases_out="$TMPDIR/cases.txt"
FORMAT=cases \
  SCHEDULER_CSV="$TMPDIR/scheduler.metrics.csv" \
  SUMMARY="$TMPDIR/scheduler.summary.log" \
  "$ROOT/tools/recommend-staircase-command.sh" >"$cases_out"

assert_contains "$cases_out" "default|" \
  "cases output includes default comparison"
assert_contains "$cases_out" "threads2||2" \
  "cases output includes selected executor thread case"

auto_dir="$TMPDIR/auto"
mkdir -p "$auto_dir"
cat >"$auto_dir/old_200.metrics.csv" <<'EOF'
tag,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra
old_200_default_r1,8.400,17.000,0,0
old_200_threads4_r1,5.200,6.000,0,0
EOF
cat >"$auto_dir/old_200.summary.log" <<'EOF'
pc_scheduler_sweep tag_prefix=old_200 runs=1 dry_run=0 fail_on_case_error=0
profile cmd_rate_hz=200 cmd_catchup_max=0 qos=best_effort depth=1 tracking=sampled status_every_n=40 sample_window=1024 summary_period_s=5.0 link_health_period_s=5.0 startup_grace_s=3.0 executor_threads=0 require_core_metrics=0 require_health_pass=0 max_catchup_events=0 max_catchup_extra=0 isolate_ros_domain_per_case=auto resolved_isolate_ros_domain_per_case=1 ros_domain_base=0 run_seconds=30 warmup_seconds=5 hz_seconds=20
START label=default run=1 tag=old_200_default_r1 prefix=none executor_threads=0 stage_ros_domain_id=0
START label=threads4 run=1 tag=old_200_threads4_r1 prefix=none executor_threads=4 stage_ros_domain_id=1
EOF
cat >"$auto_dir/new_1000.metrics.csv" <<'EOF'
tag,pc_wire_gap_p99_ms,pc_wire_gap_max_ms,pc_cmd_catchup_events,pc_cmd_catchup_extra
new_1000_threads4_r1,1.500,3.000,0,0
EOF
cat >"$auto_dir/new_1000.summary.log" <<'EOF'
pc_scheduler_sweep tag_prefix=new_1000 runs=1 dry_run=0 fail_on_case_error=0
profile cmd_rate_hz=1000 cmd_catchup_max=0 qos=best_effort depth=1 tracking=sampled status_every_n=200 sample_window=1024 summary_period_s=5.0 link_health_period_s=5.0 startup_grace_s=3.0 executor_threads=0 require_core_metrics=0 require_health_pass=0 max_catchup_events=0 max_catchup_extra=0 isolate_ros_domain_per_case=auto resolved_isolate_ros_domain_per_case=1 ros_domain_base=0 run_seconds=30 warmup_seconds=5 hz_seconds=20
START label=threads4 run=1 tag=new_1000_threads4_r1 prefix=none executor_threads=4 stage_ros_domain_id=0
EOF
touch -t 202607090101 "$auto_dir/old_200.metrics.csv" "$auto_dir/old_200.summary.log"
touch -t 202607090102 "$auto_dir/new_1000.metrics.csv" "$auto_dir/new_1000.summary.log"

auto_out="$TMPDIR/auto.md"
SCHED_LOGDIR="$auto_dir" \
  TAG_PREFIX="staircase_auto" \
  "$ROOT/tools/recommend-staircase-command.sh" >"$auto_out"

assert_contains "$auto_out" "scheduler CSV: $auto_dir/old_200.metrics.csv" \
  "auto mode skips newer non-200Hz scheduler CSV"
assert_contains "$auto_out" "selected scheduler tag: old_200_threads4_r1" \
  "auto mode selects latest matching 200Hz profile"
assert_contains "$auto_out" "'threads4||4'" \
  "auto mode includes selected 200Hz case"

echo "PASS: recommended staircase command tests"
