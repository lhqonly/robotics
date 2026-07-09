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

echo "PASS: recommended staircase command tests"
