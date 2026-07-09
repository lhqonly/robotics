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

assert_count() {
  local file="$1"
  local pattern="$2"
  local expected="$3"
  local label="$4"
  local actual
  actual="$(grep -Ec "$pattern" "$file" || true)"
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: $label expected $expected got $actual pattern=$pattern file=$file" >&2
    exit 1
  fi
}

test_summary_counter_parser() {
  local output
  output="$(
    RUN_COM_STAIRCASE_SOURCE_ONLY=1 bash -c '
      LOGDIR="$2" source "$1" __source_only
      extract_summary_counter \
        "[com-perf] last_summary=[node_com_cmd] link-health summary: sent=1 matched=1 lost=0 duplicate=1 inflight=0 stale_duplicate=0" \
        duplicate
    ' _ "$ROOT/tools/run-com-staircase.sh" "$TMPDIR/source-only"
  )"
  if [ "$output" != "1" ]; then
    echo "FAIL: summary counter parser expected duplicate=1 got '$output'" >&2
    exit 1
  fi
}

test_summary_counter_parser

LOGDIR="$TMPDIR/default" DRY_RUN=1 \
  "$ROOT/tools/run-com-staircase.sh" dry_default >/dev/null
default_summary="$TMPDIR/default/dry_default.summary.log"
assert_contains "$default_summary" "START baseline_1khz_20hz_reliable" \
  "default baseline stage"
assert_contains "$default_summary" \
  "START latest_1000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40" \
  "default 1k latest stage"
assert_contains "$default_summary" \
  "START latest_1000hz_2000000baud_irqp4_poll0_spin1000us_200hz_be_n40" \
  "default 1k latest 2Mbps stage"
assert_contains "$default_summary" \
  "SUMMARY_PERIOD_S=5.0 LINK_HEALTH_PERIOD_S=5.0" \
  "default latest diagnostic periods"
assert_contains "$default_summary" "pc_launch_prefix=none" \
  "default staircase records absent PC launch prefix"
assert_contains "$default_summary" "post_stage_settle_seconds=3" \
  "default staircase records post-stage settle"
assert_contains "$default_summary" \
  "isolate_ros_domain_per_stage=0 ros_domain_base=0" \
  "default staircase records ROS domain reuse"
assert_contains "$default_summary" \
  "START baseline_1khz_20hz_reliable stage_ros_domain_id=0" \
  "default baseline stage ROS domain"
assert_contains "$default_summary" \
  "START latest_1000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40 stage_ros_domain_id=0" \
  "default latest stage reuses ROS domain"
assert_contains "$default_summary" \
  "START latest_10000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40" \
  "default 10k latest stage"
assert_contains "$default_summary" \
  "START latest_10000hz_2000000baud_irqp4_poll0_spin1000us_200hz_be_n40" \
  "default 10k latest 2Mbps stage"
assert_count "$default_summary" '^START latest_' 8 \
  "default latest stage count"

LOGDIR="$TMPDIR/matrix" DRY_RUN=1 \
  STAIRCASE_BAUDS="921600 2000000" \
  STAIRCASE_CONTROL_TIMER_IRQ_PRIORITIES="4 5" \
  STAIRCASE_UART_READ_POLL_YIELDS="0 4" \
  STAIRCASE_EXECUTOR_SPIN_TIMEOUT_US="1000 200" \
  PC_LAUNCH_PREFIX="taskset -c 2" \
  "$ROOT/tools/run-com-staircase.sh" dry_matrix >/dev/null
matrix_summary="$TMPDIR/matrix/dry_matrix.summary.log"
assert_contains "$matrix_summary" \
  "START latest_10000hz_2000000baud_irqp5_poll4_spin200us_200hz_be_n40" \
  "expanded 10k 2Mbps irq/poll/spin stage"
assert_contains "$matrix_summary" "pc_launch_prefix=taskset -c 2" \
  "expanded staircase records PC launch prefix"
assert_count "$matrix_summary" '^START latest_' 64 \
  "expanded latest stage count"
assert_contains "$matrix_summary" "DONE failures=0" \
  "dry-run staircase completes cleanly"

LOGDIR="$TMPDIR/pc_cases" DRY_RUN=1 \
  STAIRCASE_BAUDS="921600" \
  STAIRCASE_PC_LAUNCH_PREFIX_CASES=$'default|\ntaskset_cpu2|taskset -c 2' \
  "$ROOT/tools/run-com-staircase.sh" dry_pc_cases >/dev/null
pc_cases_summary="$TMPDIR/pc_cases/dry_pc_cases.summary.log"
assert_contains "$pc_cases_summary" "staircase_pc_launch_case_count=2" \
  "PC launch case count recorded"
assert_contains "$pc_cases_summary" \
  "START latest_1000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40_pcdefault" \
  "PC case default stage suffix"
assert_contains "$pc_cases_summary" \
  "START latest_1000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40_pctaskset_cpu2" \
  "PC case taskset stage suffix"
assert_contains "$pc_cases_summary" \
  "PC_LAUNCH_PREFIX=taskset\\ -c\\ 2" \
  "PC launch prefix is passed to run-com-perf"
assert_count "$pc_cases_summary" '^START latest_' 8 \
  "PC case matrix doubles one-baud latest stages"

LOGDIR="$TMPDIR/isolated" DRY_RUN=1 STAIRCASE_ISOLATE_ROS_DOMAIN_PER_STAGE=1 \
  "$ROOT/tools/run-com-staircase.sh" dry_isolated >/dev/null
isolated_summary="$TMPDIR/isolated/dry_isolated.summary.log"
assert_contains "$isolated_summary" \
  "isolate_ros_domain_per_stage=1 ros_domain_base=0" \
  "explicit ROS domain isolation is recorded"
assert_contains "$isolated_summary" \
  "START baseline_1khz_20hz_reliable stage_ros_domain_id=0" \
  "isolated baseline starts at base ROS domain"
assert_contains "$isolated_summary" \
  "START latest_1000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40 stage_ros_domain_id=1" \
  "isolated latest stage increments ROS domain"

LOGDIR="$TMPDIR/fallback" DRY_RUN=1 STAIRCASE_FORCE_STLINK_FAIL=1 \
  "$ROOT/tools/run-com-staircase.sh" dry_fallback >/dev/null
fallback_summary="$TMPDIR/fallback/dry_fallback.summary.log"
assert_contains "$fallback_summary" \
  "BLOCKED forced ST-LINK failure via STAIRCASE_FORCE_STLINK_FAIL=1" \
  "forced ST-LINK fallback marker"
assert_contains "$fallback_summary" "SKIP flash staircase stages" \
  "fallback skips flash stages"
assert_contains "$fallback_summary" "START no_flash_smoke" \
  "fallback reliable smoke stage"
assert_contains "$fallback_summary" "START no_flash_latest_target_qos_probe" \
  "fallback latest-target QoS probe stage"
assert_contains "$fallback_summary" "REQUIRE_CORE_METRICS=0 REQUIRE_HEALTH_PASS=0" \
  "fallback QoS probe is evidence-only"
assert_contains "$fallback_summary" "QOS_RELIABILITY=best_effort" \
  "fallback QoS probe uses best-effort preset"
assert_contains "$fallback_summary" "post_stage_settle_seconds=3" \
  "fallback records post-stage settle"
assert_contains "$fallback_summary" \
  "START no_flash_smoke stage_ros_domain_id=0" \
  "fallback smoke ROS domain"
assert_contains "$fallback_summary" \
  "START no_flash_latest_target_qos_probe stage_ros_domain_id=0" \
  "fallback QoS probe reuses ROS domain by default"
assert_count "$fallback_summary" '^START latest_' 0 \
  "fallback does not run flash latest stages"

echo "PASS: communication staircase dry-run tests"
