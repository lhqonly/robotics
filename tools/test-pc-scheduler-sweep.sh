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
  CMD_RATE_HZ=200 CMD_CATCHUP_MAX=1 \
  QOS_RELIABILITY=best_effort QOS_DEPTH=1 \
  TRACKING_MODE=sampled STATUS_EVERY_N=40 SAMPLE_WINDOW=1024 \
  SUMMARY_PERIOD_S=5.0 LINK_HEALTH_PERIOD_S=5.0 \
  STARTUP_GRACE_S=3.0 EXECUTOR_THREADS=2 \
  MAX_CATCHUP_EVENTS=0 MAX_CATCHUP_EXTRA=0 \
  REQUIRE_CORE_METRICS=0 REQUIRE_HEALTH_PASS=0 \
  PC_SCHEDULER_CASES=$'default|\ntaskset_cpu2|taskset -c 2' \
  "$ROOT/tools/run-pc-scheduler-sweep.sh" dry_pc_sched >/dev/null

summary="$TMPDIR/scheduler/dry_pc_sched.summary.log"
assert_contains "$summary" \
  "profile cmd_rate_hz=200 cmd_catchup_max=1 qos=best_effort depth=1 tracking=sampled status_every_n=40 sample_window=1024 summary_period_s=5.0 link_health_period_s=5.0 startup_grace_s=3.0 executor_threads=2 require_core_metrics=0 require_health_pass=0 max_catchup_events=0 max_catchup_extra=0 isolate_ros_domain_per_case=auto resolved_isolate_ros_domain_per_case=1 ros_domain_base=0" \
  "high-rate scheduler profile"
assert_contains "$summary" \
  "DRY_RUN tag=dry_pc_sched_default_r1 PC_LAUNCH_PREFIX= EXECUTOR_THREADS=2 ROS_DOMAIN_ID=0" \
  "dry-run records executor threads for default case"
assert_contains "$summary" \
  "DRY_RUN tag=dry_pc_sched_taskset_cpu2_r1 PC_LAUNCH_PREFIX=taskset -c 2 EXECUTOR_THREADS=2 ROS_DOMAIN_ID=1" \
  "dry-run records executor threads for taskset case"

LOGDIR="$TMPDIR/scheduler_strict" COM_PERF_LOGDIR="$TMPDIR/com-perf" DRY_RUN=1 \
  PC_SCHEDULER_CASES=$'default|\ntaskset_cpu2|taskset -c 2' \
  "$ROOT/tools/run-pc-scheduler-sweep.sh" dry_pc_sched_strict >/dev/null

strict_summary="$TMPDIR/scheduler_strict/dry_pc_sched_strict.summary.log"
assert_contains "$strict_summary" \
  "require_core_metrics=1 require_health_pass=1 max_catchup_events=NA max_catchup_extra=NA isolate_ros_domain_per_case=auto resolved_isolate_ros_domain_per_case=0 ros_domain_base=0" \
  "strict communication scheduler profile reuses ROS domain by default"
assert_contains "$strict_summary" \
  "DRY_RUN tag=dry_pc_sched_strict_taskset_cpu2_r1 PC_LAUNCH_PREFIX=taskset -c 2 EXECUTOR_THREADS=0 ROS_DOMAIN_ID=0" \
  "strict communication mode keeps taskset case in base ROS domain"

echo "PASS: PC scheduler sweep tests"
