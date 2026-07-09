#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tools/firmware-linker-reserve-sweep.sh"

assert_contains() {
  local needle="$1"
  local label="$2"
  if ! grep -Fq -- "$needle" "$SCRIPT"; then
    echo "FAIL: $label missing '$needle'" >&2
    exit 1
  fi
}

bash -n "$SCRIPT"

assert_contains "RESERVE_CASES" \
  "linker reserve case configuration"
assert_contains "default:512:1024" \
  "default reserve case"
assert_contains "heap256_stack768:256:768" \
  "balanced linker reserve case"
assert_contains "heap0_stack768:0:768" \
  "heap-only intermediate reserve case"
assert_contains "heap256_stack512:256:512" \
  "msp-only intermediate reserve case"
assert_contains "heap0_stack512:0:512" \
  "minimum static RAM reserve case"
assert_contains "-DEXO_NEWLIB_HEAP_BYTES" \
  "newlib heap CMake flag"
assert_contains "-DEXO_MSP_STACK_BYTES" \
  "MSP stack CMake flag"
assert_contains "runtime_msp_heap_required" \
  "runtime MSP/heap safety gate"

echo "PASS: firmware linker reserve sweep tests"
