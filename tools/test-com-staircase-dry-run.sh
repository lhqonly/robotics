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

LOGDIR="$TMPDIR/default" DRY_RUN=1 \
  "$ROOT/tools/run-com-staircase.sh" dry_default >/dev/null
default_summary="$TMPDIR/default/dry_default.summary.log"
assert_contains "$default_summary" "START baseline_1khz_20hz_reliable" \
  "default baseline stage"
assert_contains "$default_summary" \
  "START latest_1000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40" \
  "default 1k latest stage"
assert_contains "$default_summary" \
  "SUMMARY_PERIOD_S=5.0 LINK_HEALTH_PERIOD_S=5.0" \
  "default latest diagnostic periods"
assert_contains "$default_summary" "pc_launch_prefix=none" \
  "default staircase records absent PC launch prefix"
assert_contains "$default_summary" \
  "START latest_10000hz_921600baud_irqp4_poll0_spin1000us_200hz_be_n40" \
  "default 10k latest stage"
assert_count "$default_summary" '^START latest_' 4 \
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

echo "PASS: communication staircase dry-run tests"
