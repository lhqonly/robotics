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
    exit 1
  fi
}

LOGDIR="$TMPDIR/scheduler" COM_PERF_LOGDIR="$TMPDIR/com-perf" DRY_RUN=1 \
  "$ROOT/tools/run-pc-latest-scheduler-sweep.sh" dry_latest_sched >/dev/null

summary="$TMPDIR/scheduler/dry_latest_sched.summary.log"
assert_contains "$summary" \
  "profile cmd_rate_hz=200 cmd_catchup_max=0 qos=best_effort depth=1 tracking=sampled status_every_n=40 sample_window=1024 summary_period_s=5.0 link_health_period_s=5.0 startup_grace_s=3.0 executor_threads=0 require_core_metrics=0 require_health_pass=0 max_catchup_events=0 max_catchup_extra=0 isolate_ros_domain_per_case=auto resolved_isolate_ros_domain_per_case=1 ros_domain_base=0 run_seconds=30 warmup_seconds=5 hz_seconds=20" \
  "latest-target scheduler wrapper profile"
assert_contains "$summary" \
  "DRY_RUN tag=dry_latest_sched_default_r1 PC_LAUNCH_PREFIX= EXECUTOR_THREADS=0 ROS_DOMAIN_ID=0" \
  "latest-target wrapper includes default case"
assert_contains "$summary" \
  "DRY_RUN tag=dry_latest_sched_threads2_r1 PC_LAUNCH_PREFIX= EXECUTOR_THREADS=2 ROS_DOMAIN_ID=1" \
  "latest-target wrapper includes threads2 case"
assert_contains "$summary" \
  "DRY_RUN tag=dry_latest_sched_threads4_r1 PC_LAUNCH_PREFIX= EXECUTOR_THREADS=4 ROS_DOMAIN_ID=2" \
  "latest-target wrapper includes threads4 case"

LOGDIR="$TMPDIR/custom" COM_PERF_LOGDIR="$TMPDIR/com-perf" DRY_RUN=1 \
  RUN_SECONDS=5 PC_SCHEDULER_CASES=$'custom1||1' \
  "$ROOT/tools/run-pc-latest-scheduler-sweep.sh" dry_latest_custom >/dev/null

custom_summary="$TMPDIR/custom/dry_latest_custom.summary.log"
assert_contains "$custom_summary" \
  "run_seconds=5 warmup_seconds=5 hz_seconds=20" \
  "latest-target wrapper allows runtime overrides"
assert_contains "$custom_summary" \
  "DRY_RUN tag=dry_latest_custom_custom1_r1 PC_LAUNCH_PREFIX= EXECUTOR_THREADS=1 ROS_DOMAIN_ID=0" \
  "latest-target wrapper respects custom cases"

echo "PASS: PC latest-target scheduler sweep wrapper tests"
