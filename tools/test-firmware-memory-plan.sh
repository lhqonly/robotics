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
assert_contains "## Current RAM Categories" \
  "RAM category section"
assert_contains "ram_category_summary" \
  "firmware-size-report category output"
assert_contains "rosidl_type_metadata" \
  "ROSIDL metadata category"
assert_contains "## micro-ROS Stack Candidates" \
  "stack candidate section"
assert_contains "## Executor Spin Timeout Candidates" \
  "spin candidate section"
assert_contains "## Linker Heap/MSP Reserve Candidates" \
  "linker candidate section"
assert_contains "## Static Size Matrix Contract" \
  "static size matrix contract section"
assert_contains "firmware_size_matrix_contract" \
  "static size matrix contract output"
assert_contains "## Optimization Recommendations" \
  "optimization recommendation section"
assert_contains "RECOMMENDATION default_policy=keep_defaults_until_runtime_evidence" \
  "default recommendation policy"
assert_contains "CANDIDATE linker_reserve_min_static" \
  "linker reserve recommendation"
assert_contains "Do not change default micro-ROS task stack" \
  "hardware HWM guardrail"

echo "PASS: firmware memory optimization plan tests"
