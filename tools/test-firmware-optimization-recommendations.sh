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
    echo "output:" >&2
    cat "$file" >&2
    exit 1
  fi
}

actual_out="$TMPDIR/actual.md"
"$ROOT/tools/recommend-firmware-optimizations.sh" >"$actual_out"
assert_contains "$actual_out" "# Firmware Optimization Recommendations" \
  "recommendation title"
assert_contains "$actual_out" \
  "RECOMMENDATION default_policy=keep_defaults_until_runtime_evidence" \
  "default keep policy"
assert_contains "$actual_out" "CANDIDATE microros_stack_min_static" \
  "stack recommendation"
assert_contains "$actual_out" "CANDIDATE linker_reserve_min_static" \
  "linker recommendation"
assert_contains "$actual_out" "CANDIDATE combined_stack_linker_min_static" \
  "combined stack/linker recommendation"
assert_contains "$actual_out" "CANDIDATE rosidl_type_metadata" \
  "ROSIDL metadata recommendation"
assert_contains "$actual_out" "CANDIDATE rosidl_raw_source_metadata" \
  "ROSIDL raw source metadata recommendation"
assert_contains "$actual_out" "SWD_STATUS=ok" \
  "runtime SWD gate"

cat >"$TMPDIR/size.csv" <<'EOF'
profile,ram_static_bytes,ram_rosidl_type_metadata_bytes,ram_rosidl_raw_source_metadata_bytes,ram_microros_custom_pools_bytes
default_reliable_1khz,15000,3000,1555,2000
besteffort_10000hz_status40,14000,3000,1555,2000
EOF
cat >"$TMPDIR/stack.csv" <<'EOF'
microros_stack_words,verdict,ram_static_bytes
768,PASS_STATIC,14000
704,PASS_STATIC,13744
640,PASS_STATIC,13488
EOF
cat >"$TMPDIR/spin.csv" <<'EOF'
executor_spin_timeout_us,verdict,ram_static_bytes
1000,PASS_STATIC,14000
200,PASS_STATIC,14000
EOF
cat >"$TMPDIR/linker.csv" <<'EOF'
case,verdict,ram_static_bytes
default,PASS_STATIC,14000
heap0_stack512,PASS_STATIC,13000
EOF
cat >"$TMPDIR/combined.csv" <<'EOF'
case,verdict,ram_static_bytes
baseline,PASS_STATIC,14000
stack640_heap0_stack512,PASS_STATIC,12488
EOF
cat >"$TMPDIR/size-report.txt" <<'EOF'
rosidl_type_metadata_breakdown:
ExoHeader                bytes=   511
ExoCmd                   bytes=   347
ExoStatus                bytes=   350
toplevel_type_raw_source bytes=  1555
other_rosidl_metadata    bytes=    72
EOF

synthetic_out="$TMPDIR/synthetic.md"
SIZE_MATRIX_CSV="$TMPDIR/size.csv" \
  STACK_CSV="$TMPDIR/stack.csv" \
  SPIN_CSV="$TMPDIR/spin.csv" \
  LINKER_CSV="$TMPDIR/linker.csv" \
  COMBINED_CSV="$TMPDIR/combined.csv" \
  FIRMWARE_SIZE_REPORT="$TMPDIR/size-report.txt" \
  "$ROOT/tools/recommend-firmware-optimizations.sh" >"$synthetic_out"

assert_contains "$synthetic_out" \
  "CANDIDATE tim2_high_loop_static_saving saved_bytes=1000" \
  "synthetic TIM2/static profile saving"
assert_contains "$synthetic_out" \
  "CANDIDATE microros_stack_min_static words=640 saved_bytes=512" \
  "synthetic stack saving"
assert_contains "$synthetic_out" \
  "CANDIDATE linker_reserve_min_static case=heap0_stack512 saved_bytes=1000" \
  "synthetic linker reserve saving"
assert_contains "$synthetic_out" \
  "CANDIDATE combined_stack_linker_min_static case=stack640_heap0_stack512 saved_bytes=1512" \
  "synthetic combined stack/linker saving"
assert_contains "$synthetic_out" \
  "CANDIDATE rosidl_type_metadata bytes=3000" \
  "synthetic ROSIDL metadata bytes"
assert_contains "$synthetic_out" \
  "CANDIDATE rosidl_raw_source_metadata bytes=1555 parent_bytes=3000" \
  "synthetic ROSIDL raw source metadata bytes"

echo "PASS: firmware optimization recommendation tests"
