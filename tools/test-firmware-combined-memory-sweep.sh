#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tools/firmware-combined-memory-sweep.sh"

assert_contains() {
  local needle="$1"
  local label="$2"
  if ! grep -Fq -- "$needle" "$SCRIPT"; then
    echo "FAIL: $label missing '$needle'" >&2
    exit 1
  fi
}

bash -n "$SCRIPT"

assert_contains "COMBINED_MEMORY_CASES" \
  "combined case configuration"
assert_contains "baseline:768:512:1024" \
  "baseline case"
assert_contains "stack704:704:512:1024" \
  "intermediate stack-only candidate"
assert_contains "stack704_heap0_stack512:704:0:512" \
  "intermediate combined stack/linker candidate"
assert_contains "stack640_heap0_stack512:640:0:512" \
  "combined minimum static RAM case"
assert_contains "-DEXO_MICROROS_TASK_STACK_WORDS" \
  "micro-ROS stack CMake flag"
assert_contains "MOTOR_ROS_ENTITIES" \
  "motor entity sweep configuration"
assert_contains "-DEXO_MOTOR_ROS_ENTITIES" \
  "motor entity CMake flag"
assert_contains "motor_ros_entities" \
  "motor entity CSV column"
assert_contains "motor entities" \
  "motor entity markdown column"
assert_contains "-DEXO_NEWLIB_HEAP_BYTES" \
  "newlib heap CMake flag"
assert_contains "-DEXO_MSP_STACK_BYTES" \
  "MSP stack CMake flag"
assert_contains "runtime_hwm_msp_heap_required" \
  "combined runtime safety gate"

echo "PASS: firmware combined memory sweep tests"
