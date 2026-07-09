#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

out="$("$ROOT/tools/summarize-firmware-memory-plan.sh")"
printf '%s\n' "$out" >"$TMPDIR/memory-plan.md"

assert_contains() {
  local needle="$1"
  local label="$2"
  if ! grep -Fq -- "$needle" "$TMPDIR/memory-plan.md"; then
    echo "FAIL: $label missing '$needle'" >&2
    exit 1
  fi
}

assert_contains "# Firmware Memory Optimization Snapshot" \
  "memory plan title"
assert_contains "## Default/Non-Motor ELF RAM Categories" \
  "default/non-motor RAM category section"
assert_contains "default/non-motor ELF categories are not M2 motor memory conclusions" \
  "default/non-motor scope warning"
assert_contains "ram_category_summary" \
  "firmware-size-report category output"
assert_contains "rosidl_type_metadata" \
  "ROSIDL metadata category"
assert_contains "## Motor-Enabled Static Delta" \
  "motor-enabled static delta section"
assert_contains "motor-default" \
  "motor default profile row"
assert_contains "motor-opt" \
  "motor optimized profile row"
assert_contains "ram_static_saved_bytes=" \
  "motor static RAM delta"
assert_contains "gate=motor_enabled_stack_hwm_msp_heap_reconnect_soak" \
  "motor runtime gate"
assert_contains "## Motor-Enabled RAM Categories" \
  "motor-enabled RAM category section"
assert_contains "## Motor-Enabled ROSIDL Metadata" \
  "motor-enabled ROSIDL metadata section"
assert_contains "JointTarget" \
  "motor JointTarget metadata row"
assert_contains "JointState" \
  "motor JointState metadata row"
assert_contains "MotorHealth" \
  "motor MotorHealth metadata row"
assert_contains "## micro-ROS Stack Candidates" \
  "stack candidate section"
assert_contains "## Executor Spin Timeout Candidates" \
  "spin candidate section"
assert_contains "## Linker Heap/MSP Reserve Candidates" \
  "linker candidate section"
assert_contains "## Combined Stack/Linker Candidates" \
  "combined stack/linker candidate section"
assert_contains "## Static Size Matrix Contract" \
  "static size matrix contract section"
assert_contains "firmware_size_matrix_contract" \
  "static size matrix contract output"
assert_contains "## Optimization Recommendations" \
  "optimization recommendation section"
assert_contains "RECOMMENDATION default_policy=keep_defaults_until_runtime_evidence" \
  "default recommendation policy"
assert_contains "SCOPE_NOTE default_non_motor_candidates_are_not_motor_memory_conclusions" \
  "recommendation scope note"
assert_contains "CANDIDATE linker_reserve_min_static" \
  "linker reserve recommendation"
assert_contains "CANDIDATE linker_reserve_intermediate" \
  "intermediate linker reserve recommendation"
assert_contains "CANDIDATE motor_tim2_high_loop_static_saving" \
  "motor high-loop static saving recommendation"
assert_contains "CANDIDATE microros_stack_intermediate" \
  "intermediate stack recommendation"
assert_contains "CANDIDATE combined_stack_linker_balanced_intermediate" \
  "balanced intermediate combined stack/linker recommendation"
assert_contains "CANDIDATE combined_stack_linker_intermediate" \
  "intermediate combined stack/linker recommendation"
assert_contains "CANDIDATE combined_stack_linker_min_static" \
  "combined stack/linker recommendation"
assert_contains "Do not change default micro-ROS task stack" \
  "hardware HWM guardrail"
assert_contains "combined stack/linker savings" \
  "combined runtime guardrail"

echo "PASS: firmware memory optimization plan tests"
